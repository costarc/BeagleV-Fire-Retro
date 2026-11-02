//
// BeagleV-Fire multicore, MSX1: the machine's ROMs in DDR. One AXI4 master on FIC0 (the same port as the probe bvf_ddr) serves
//   * the Z80: single byte reads and writes (an 8 byte beat with the byte strobe), the core waits through mem_ready,
//   * the frame capture: one 8 byte write per request (8 pixels), to the capture window.
//
// Address map (byte address, base BASE = $C800_0000, the 32 MB reserved region "buffer@c8000000"):
//   BASE + 0x000000.. : the machine's flat 25 bit address (bvf_msx1.v: the ROMs at 0x620000.., the RAM is on chip)
//   BASE + 0x1000000.. : the frame capture window (cap_off is an 8 byte word offset inside it)
//
// The core side runs on clk (42 MHz), the AXI side on aclk (125 MHz); a request and its answer cross by toggles (the values are
// stable long before the toggle is seen), as in bvf_ddr.
//
module bvf_msxmem (
	input         clk,
	input         reset,
	// the Z80 (clk)
	input         cpu_start,               // one clock pulse: start the access below
	input         cpu_we,
	input  [24:0] cpu_adr,
	input   [7:0] cpu_wd,
	output        cpu_ready,               // 0 from the clock after the start until the access is done
	output  [7:0] cpu_rd,
	output [63:0] cpu_rq64,                // the whole 8 byte word of the last read (for a cache line)
	// the frame capture (clk)
	input         cap_start,               // one clock pulse (ignored while cap_busy)
	input  [21:0] cap_off,                 // 8 byte word offset in the capture window
	input  [63:0] cap_data,
	output        cap_busy,

	// AXI4 master (aclk)
	input         aclk,
	input         aresetn,
	output reg  [3:0] m_awid,
	output reg [37:0] m_awaddr,
	output reg  [7:0] m_awlen,
	output      [2:0] m_awsize,
	output      [1:0] m_awburst,
	output            m_awlock,
	output      [3:0] m_awcache,
	output      [2:0] m_awprot,
	output      [3:0] m_awqos,
	output reg        m_awvalid,
	input             m_awready,
	output reg [63:0] m_wdata,
	output reg  [7:0] m_wstrb,
	output reg        m_wlast,
	output reg        m_wvalid,
	input             m_wready,
	input       [3:0] m_bid,
	input       [1:0] m_bresp,
	input             m_bvalid,
	output reg        m_bready,
	output reg  [3:0] m_arid,
	output reg [37:0] m_araddr,
	output reg  [7:0] m_arlen,
	output      [2:0] m_arsize,
	output      [1:0] m_arburst,
	output            m_arlock,
	output      [3:0] m_arcache,
	output      [2:0] m_arprot,
	output      [3:0] m_arqos,
	output reg        m_arvalid,
	input             m_arready,
	input       [3:0] m_rid,
	input      [63:0] m_rdata,
	input       [1:0] m_rresp,
	input             m_rlast,
	input             m_rvalid,
	output reg        m_rready
);

localparam [37:0] BASE = 38'h00_C800_0000;
localparam [37:0] CAPB = 38'h00_C900_0000;

assign m_awsize = 3'd3, m_arsize = 3'd3, m_awburst = 2'b01, m_arburst = 2'b01;
assign m_awlock = 1'b0, m_arlock = 1'b0, m_awcache = 4'b0000, m_arcache = 4'b0000, m_awprot = 3'b000, m_arprot = 3'b000;
assign m_awqos = 4'd0, m_arqos = 4'd0;

// ---------------------------------------------------------------- core clock side
reg         c_we;
reg  [24:0] c_adr;
reg   [7:0] c_wd;
reg         c_t = 1'b0;
reg   [1:0] c_ak_s = 2'b00;
reg         k_t = 1'b0;
reg  [21:0] k_off;
reg  [63:0] k_data;
reg   [1:0] k_ak_s = 2'b00;
wire        c_ak, k_ak;              // from the aclk side (toggles)
wire  [7:0] c_q;                     // read byte, stable before c_ak toggles

// while `reset` is high the aclk side follows the request toggles (its answers equal the requests: idle), so a request that was
// cut off by a reset cannot come back as a phantom answer; the core side needs no reset of its own.
always @(posedge clk) begin
	c_ak_s <= {c_ak_s[0], c_ak};
	k_ak_s <= {k_ak_s[0], k_ak};
	if (cpu_start && cpu_ready) begin
		c_we <= cpu_we; c_adr <= cpu_adr; c_wd <= cpu_wd;
		c_t <= ~c_t;
	end
	if (cap_start && !cap_busy) begin
		k_off <= cap_off; k_data <= cap_data;
		k_t <= ~k_t;
	end
end
assign cpu_ready = (c_t == c_ak_s[1]);
assign cap_busy  = (k_t != k_ak_s[1]);
assign cpu_rd = c_q;                 // changed at least two clocks before cpu_ready rises

// ---------------------------------------------------------------- AXI side
reg   [1:0] c_t_s = 2'b00, k_t_s = 2'b00;
reg         c_ak_r = 1'b0, k_ak_r = 1'b0;
reg   [7:0] c_q_r;
reg  [63:0] c_q64_r;
assign cpu_rq64 = c_q64_r;           // stable before cpu_ready rises, as cpu_rd
assign c_ak = c_ak_r;
assign k_ak = k_ak_r;
assign c_q  = c_q_r;

localparam S_IDLE = 3'd0, S_AR = 3'd1, S_R = 3'd2, S_AW = 3'd3, S_B = 3'd4;
reg   [2:0] st;
reg         for_k;                  // the current access is the capture's
reg         awd, wd_d;
reg   [2:0] lane;

reg   [1:0] rst_s = 2'b11;
wire        arst = ~aresetn | rst_s[1];

always @(posedge aclk) begin
	c_t_s <= {c_t_s[0], c_t};
	k_t_s <= {k_t_s[0], k_t};
	rst_s <= {rst_s[0], reset};
	if (arst) begin
		st <= S_IDLE;
		m_arvalid <= 1'b0; m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_wlast <= 1'b0; m_rready <= 1'b0; m_bready <= 1'b0;
		m_arid <= 4'd0; m_awid <= 4'd0; m_arlen <= 8'd0; m_awlen <= 8'd0; m_araddr <= 38'd0; m_awaddr <= 38'd0;
		m_wdata <= 64'd0; m_wstrb <= 8'd0;
		c_ak_r <= c_t_s[1]; k_ak_r <= k_t_s[1];
		for_k <= 1'b0;
	end else begin
		case (st)
		S_IDLE: begin
			if (c_t_s[1] != c_ak_r) begin
				for_k <= 1'b0;
				lane <= c_adr[2:0];
				if (c_we) begin
					st <= S_AW; m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_wlast <= 1'b1; m_awlen <= 8'd0;
					m_awaddr <= BASE + {13'd0, c_adr[24:3], 3'b000};
					m_wdata <= {8{c_wd}}; m_wstrb <= 8'd1 << c_adr[2:0];
					awd <= 1'b0; wd_d <= 1'b0;
				end else begin
					st <= S_AR; m_arvalid <= 1'b1; m_arlen <= 8'd0;
					m_araddr <= BASE + {13'd0, c_adr[24:3], 3'b000};
				end
			end else if (k_t_s[1] != k_ak_r) begin
				for_k <= 1'b1;
				st <= S_AW; m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_wlast <= 1'b1; m_awlen <= 8'd0;
				m_awaddr <= CAPB + {13'd0, k_off, 3'b000};
				m_wdata <= k_data; m_wstrb <= 8'hFF;
				awd <= 1'b0; wd_d <= 1'b0;
			end
		end
		S_AR: if (m_arready) begin m_arvalid <= 1'b0; m_rready <= 1'b1; st <= S_R; end
		S_R: if (m_rvalid) begin
			m_rready <= 1'b0;
			c_q_r <= m_rdata[8 * lane +: 8];
			c_q64_r <= m_rdata;
			c_ak_r <= ~c_ak_r;
			st <= S_IDLE;
		end
		S_AW: begin
			if (m_awvalid && m_awready) begin m_awvalid <= 1'b0; awd <= 1'b1; end
			if (m_wvalid && m_wready) begin m_wvalid <= 1'b0; m_wlast <= 1'b0; wd_d <= 1'b1; end
			if ((awd || (m_awvalid && m_awready)) && (wd_d || (m_wvalid && m_wready))) begin m_bready <= 1'b1; st <= S_B; end
		end
		S_B: if (m_bvalid) begin
			m_bready <= 1'b0;
			if (for_k) k_ak_r <= ~k_ak_r; else c_ak_r <= ~c_ak_r;
			st <= S_IDLE;
		end
		default: st <= S_IDLE;
		endcase
	end
end

endmodule
