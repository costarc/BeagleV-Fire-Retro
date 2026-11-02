//
// BeagleV-Fire: a probe of the DDR path of the fabric. An AXI4 master on FIC0's fabric-to-processor port
// (64 bit data, 38 bit address) reads and writes the DDR through the MSS, and measures how long it takes.
// It is what the machines' memory in DDR (the MSX1's ROMs) was designed from: nothing is known about the latency
// until it is measured on the board, under Linux load.
//
// The host (the daemon, register block bvf_regs) sets MODE, ADDR, WDATA, COUNT and starts; the answer is
// RDATA and the statistics. The AXI side runs on its own clock (FIC_0_ACLK); the request and the answer cross
// by toggles (the values are stable long before the toggle is seen).
//
// CTRL: b2:0 mode, b3 start, b4 ABORT (level: the AXI side is held in reset while it is set; use it if the MSS never answers,
//       then clear it again)
//
//   MODE 1  one 64 bit read of ADDR                              2  one write of WDATA
//        3  COUNT reads of consecutive words, one at a time: LAT_MIN / LAT_MAX / LAT_SUM in ACLK cycles
//        4  COUNT writes (WDATA, then + 1 per word), one at a time, waiting for the write response
//        5  COUNT bursts of 16 words (ARLEN = 15), one at a time: TOTAL = ACLK cycles for the whole run
//        6  write COUNT words of an address pattern, read them back and compare: ERRORS
//        7  count 2^20 ACLK cycles (T42 gives the core clock cycles it took: the ACLK frequency)
//
// Address: ADDR_HI:ADDR_LO is a byte address, 8 byte aligned. In Linux the 32 MB at $C800_0000 (reserved-memory
// "buffer@c8000000", the non-cached view of DDR) are free for this.
//
module bvf_ddr (
	input         clk,                  // core clock
	input         reset,

	// registers (core clock); widx = register word index (addr[7:2]), wdata shared
	input         wr,
	input   [5:0] widx,
	input  [31:0] wdata,
	input   [5:0] ridx,
	output reg [31:0] rq,

	// AXI4 master (ACLK)
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
	output      [7:0] m_wstrb,
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

assign m_awsize = 3'd3, m_arsize = 3'd3, m_awburst = 2'b01, m_arburst = 2'b01;
assign m_awlock = 1'b0, m_arlock = 1'b0, m_awcache = 4'b0000, m_arcache = 4'b0000, m_awprot = 3'b000, m_arprot = 3'b000;
assign m_awqos = 4'd0, m_arqos = 4'd0, m_wstrb = 8'hFF;

// ---------------------------------------------------------------- core clock side: registers and the toggles
reg  [2:0] mode;
reg        abort = 1'b0;
reg [31:0] addr_lo, addr_hi, w_lo, w_hi, count;
reg        t_req = 1'b0;
reg        t_done = 1'b0;                // ACLK side
reg  [2:0] t_done_s = 3'b000;
reg        busy = 1'b0, done = 1'b0;
reg [31:0] t42;

// results from the ACLK side (stable while done)
reg [63:0] r_data;
reg [31:0] r_min, r_max, r_sum, r_total, r_err;
reg  [1:0] r_resp;

always @(posedge clk) begin
	t_done_s <= {t_done_s[1:0], t_done};
	if (reset) begin
		t_req <= 1'b0; busy <= 1'b0; done <= 1'b0; mode <= 3'd0;
		addr_lo <= 32'd0; addr_hi <= 32'd0; w_lo <= 32'd0; w_hi <= 32'd0; count <= 32'd1;
	end else begin
		if (wr) case (widx)
		6'h18: begin
			mode <= wdata[2:0];
			abort <= wdata[4];
			if (wdata[3] && !busy) begin t_req <= ~t_req; busy <= 1'b1; done <= 1'b0; t42 <= 32'd0; end
		end
		6'h19: addr_lo <= wdata;
		6'h1A: addr_hi <= wdata;
		6'h1B: w_lo <= wdata;
		6'h1C: w_hi <= wdata;
		6'h1D: count <= wdata;
		default: ;
		endcase
		if (busy) t42 <= t42 + 32'd1;
		// the answer is there when the done toggle (synchronised) equals the request toggle
		if (busy && t_done_s[2] == t_req) begin busy <= 1'b0; done <= 1'b1; end
	end
end

always @(*) begin
	case (ridx)
	6'h18: rq = {27'd0, abort, busy, mode};
	6'h19: rq = addr_lo;
	6'h1A: rq = addr_hi;
	6'h1B: rq = w_lo;
	6'h1C: rq = w_hi;
	6'h1D: rq = count;
	6'h1E: rq = r_data[31:0];
	6'h1F: rq = r_data[63:32];
	6'h20: rq = r_min;
	6'h21: rq = r_max;
	6'h22: rq = r_sum;
	6'h23: rq = r_total;
	6'h24: rq = {r_err[27:0], r_resp, busy, done};
	6'h25: rq = t42;
	default: rq = 32'd0;
	endcase
end

// ---------------------------------------------------------------- ACLK side
// the request values, taken by the ACLK side when `go` (they are stable: the host wrote them before the toggle)
wire  [2:0] mode_a    = mode;
wire [31:0] addr_lo_a = addr_lo, addr_hi_a = addr_hi, w_lo_a = w_lo, w_hi_a = w_hi, count_a = count;
reg  [2:0] t_req_s = 3'b000;
reg  [1:0] abort_s = 2'b00;
wire       go = t_req_s[2] != t_req_s[1];

localparam S_IDLE = 4'd0, S_AR = 4'd1, S_R = 4'd2, S_AW = 4'd3, S_B = 4'd4, S_NEXT = 4'd5, S_MEAS = 4'd6, S_FIN = 4'd7;
reg  [3:0] st;
reg  [2:0] m;
reg [37:0] a, a0;
reg [31:0] n, i;
reg [31:0] lat;
reg  [3:0] beats;
reg        phase2;                       // mode 6: the read-back
reg        awd, wd;
reg [31:0] o_min, o_max, o_sum, o_total, o_err;
reg [63:0] o_data;
reg  [1:0] o_resp;

wire [63:0] pat = {a[31:0] + 32'd1, a[31:0] ^ 32'hA5A5A5A5};

always @(posedge aclk) begin
	t_req_s <= {t_req_s[1:0], t_req};
	abort_s <= {abort_s[0], abort};
	if (!aresetn || abort_s[1]) begin
		st <= S_IDLE; m_arvalid <= 1'b0; m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_wlast <= 1'b0; m_rready <= 1'b0; m_bready <= 1'b0;
		m_arid <= 4'd0; m_awid <= 4'd0; m_arlen <= 8'd0; m_awlen <= 8'd0; m_araddr <= 38'd0; m_awaddr <= 38'd0; m_wdata <= 64'd0;
		t_done <= t_req_s[2];             // nothing pending after a reset
	end else begin
		case (st)
		S_IDLE: if (go) begin
			m <= mode_a; a <= {addr_hi_a[5:0], addr_lo_a}; a0 <= {addr_hi_a[5:0], addr_lo_a};
			n <= (mode_a == 3'd1 || mode_a == 3'd2) ? 32'd1 : count_a; i <= 32'd0;
			o_min <= 32'hFFFFFFFF; o_max <= 32'd0; o_sum <= 32'd0; o_total <= 32'd0; o_err <= 32'd0; o_resp <= 2'b00; phase2 <= 1'b0;
			lat <= 32'd0; awd <= 1'b0; wd <= 1'b0;
			case (mode_a)
			3'd1, 3'd3, 3'd5: begin st <= S_AR; m_arvalid <= 1'b1; m_araddr <= {addr_hi_a[5:0], addr_lo_a}; m_arlen <= (mode_a == 3'd5) ? 8'd15 : 8'd0; end
			3'd2, 3'd4, 3'd6: begin
				st <= S_AW; m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_wlast <= 1'b1; m_awlen <= 8'd0;
				m_awaddr <= {addr_hi_a[5:0], addr_lo_a};
				m_wdata <= (mode_a == 3'd6) ? {addr_lo_a + 32'd1, addr_lo_a ^ 32'hA5A5A5A5} : {w_hi_a, w_lo_a};
			end
			3'd7: begin st <= S_MEAS; lat <= 32'd0; end
			default: st <= S_FIN;
			endcase
		end

		S_AR: begin
			lat <= lat + 32'd1;
			if (m_arready) begin m_arvalid <= 1'b0; m_rready <= 1'b1; beats <= 4'd0; st <= S_R; end
		end
		S_R: begin
			lat <= lat + 32'd1;
			if (m_rvalid) begin
				o_resp <= m_rresp;
				if (m == 3'd6 && m_rdata != pat) o_err <= o_err + 32'd1;
				if (m == 3'd1 || m == 3'd3) o_data <= m_rdata;
				if (m_rlast) begin
					m_rready <= 1'b0;
					st <= S_NEXT;
					if (lat < o_min) o_min <= lat;
					if (lat > o_max) o_max <= lat;
					o_sum <= o_sum + lat;
					o_total <= o_total + lat;
				end
			end
		end

		S_AW: begin
			lat <= lat + 32'd1;
			if (m_awvalid && m_awready) begin m_awvalid <= 1'b0; awd <= 1'b1; end
			if (m_wvalid && m_wready) begin m_wvalid <= 1'b0; m_wlast <= 1'b0; wd <= 1'b1; end
			if ((awd || (m_awvalid && m_awready)) && (wd || (m_wvalid && m_wready))) begin m_bready <= 1'b1; st <= S_B; end
		end
		S_B: begin
			lat <= lat + 32'd1;
			if (m_bvalid) begin
				m_bready <= 1'b0; o_resp <= m_bresp;
				st <= S_NEXT;
				if (lat < o_min) o_min <= lat;
				if (lat > o_max) o_max <= lat;
				o_sum <= o_sum + lat;
				o_total <= o_total + lat;
			end
		end

		S_NEXT: begin
			i <= i + 32'd1;
			lat <= 32'd0; awd <= 1'b0; wd <= 1'b0;
			if (i + 32'd1 >= n) begin
				if (m == 3'd6 && !phase2) begin          // the writes are done: read them back
					phase2 <= 1'b1; i <= 32'd0; a <= a0;
					st <= S_AR; m_arvalid <= 1'b1; m_araddr <= a0; m_arlen <= 8'd0;
				end else st <= S_FIN;
			end else begin
				case (m)
				3'd3: begin a <= a + 38'd8; m_araddr <= a + 38'd8; m_arvalid <= 1'b1; st <= S_AR; end
				3'd5: begin a <= a + 38'd128; m_araddr <= a + 38'd128; m_arvalid <= 1'b1; st <= S_AR; end
				3'd4: begin a <= a + 38'd8; m_awaddr <= a + 38'd8; m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_wlast <= 1'b1;
				            m_wdata <= m_wdata + 64'd1; st <= S_AW; end
				3'd6: begin
					a <= a + 38'd8;
					if (!phase2) begin
						m_awaddr <= a + 38'd8; m_awvalid <= 1'b1; m_wvalid <= 1'b1; m_wlast <= 1'b1;
						m_wdata <= {a[31:0] + 32'd9, (a[31:0] + 32'd8) ^ 32'hA5A5A5A5}; st <= S_AW;
					end else begin m_araddr <= a + 38'd8; m_arvalid <= 1'b1; st <= S_AR; end
				end
				default: st <= S_FIN;
				endcase
			end
		end

		S_MEAS: begin                             // 2^20 ACLK cycles
			lat <= lat + 32'd1;
			if (lat == 32'd1048575) begin o_total <= 32'd1048576; st <= S_FIN; end
		end

		S_FIN: begin
			t_done <= t_req_s[2];
			st <= S_IDLE;
		end
		default: st <= S_IDLE;
		endcase
	end
end

// results to the core side: copied when the toggle says done (the ACLK side holds them until the next request)
always @(*) begin
	r_data = o_data; r_min = (o_min == 32'hFFFFFFFF) ? 32'd0 : o_min; r_max = o_max; r_sum = o_sum; r_total = o_total;
	r_err = o_err; r_resp = o_resp;
end

endmodule
