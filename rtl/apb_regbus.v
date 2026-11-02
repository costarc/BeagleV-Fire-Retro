//
// CP-300 FPGA, BeagleV-Fire: APB3 slave (PCLK) to the simple register bus of bvf_regs (clk, core clock).
//
// The BeagleV-Fire gateware framework hands a component an APB slave port (the cape example of its docs
// shows PCLK / PRESETN and an APB slave read-data net). This is the same job as axil_regbus.v for that
// kind of port. The framework's APB window size and base address are NOT known here: ABITS is how many
// address bits the window has. bvf_regs needs 20 (1 MB); if the framework gives less, use PAGED = 1: the
// top bits come from a page register at byte offset 0xFFC of the window (write it first), and the lower
// ABITS-? bits address inside the page. With PAGED = 0 the window is used as it is.
//
module apb_regbus #(parameter ABITS = 20, parameter PAGED = 0) (
	input             pclk,
	input             presetn,
	input  [ABITS-1:0] paddr,
	input             psel,
	input             penable,
	input             pwrite,
	input      [31:0] pwdata,
	output reg [31:0] prdata,
	output reg        pready,
	output            pslverr,

	input             clk,
	output reg [19:0] b_addr,
	output reg        b_wr,
	output reg [31:0] b_wdata,
	output reg        b_rd,
	input      [31:0] b_rdata
);

assign pslverr = 1'b0;

// ---------------------------------------------------------------- pclk side
reg        req_tog = 1'b0, busy = 1'b0, is_wr = 1'b0;
reg [19:0] r_addr;
reg [31:0] r_wdata;
reg        ack1 = 1'b0, ack2 = 1'b0;
reg        ack_tog = 1'b0;          // driven in the clk domain
reg [31:0] r_rdata;                 // written in the clk domain, read here after the acknowledge
reg  [7:0] page = 8'd0;             // PAGED: address bits 19:12 (the window's low 12 bits are the page offset)

wire [31:0] pa = paddr;               // zero extended: ABITS may be less than 20 when PAGED
wire       page_sel = PAGED != 0 && pa[11:0] == 12'hFFC;
wire [19:0] full = PAGED != 0 ? {page, pa[11:0]} : pa[19:0];

always @(posedge pclk) begin
	ack1 <= ack_tog; ack2 <= ack1;
	pready <= 1'b0;
	if (!presetn) begin
		req_tog <= 1'b0; busy <= 1'b0; page <= 8'd0;
	end else if (psel && penable && !busy && !pready) begin
		if (page_sel) begin
			if (pwrite) page <= pwdata[7:0];
			prdata <= {24'd0, page};
			pready <= 1'b1;
		end else begin
			r_addr <= full; r_wdata <= pwdata; is_wr <= pwrite;
			req_tog <= ~req_tog; busy <= 1'b1;
		end
	end else if (busy && ack2 == req_tog) begin
		busy <= 1'b0;
		prdata <= r_rdata;
		pready <= 1'b1;
	end
end

// ---------------------------------------------------------------- clk side
reg rq1 = 1'b0, rq2 = 1'b0, rq3 = 1'b0;
reg [1:0] cs = 2'd0;
initial begin b_wr = 1'b0; b_rd = 1'b0; end

always @(posedge clk) begin
	rq1 <= req_tog; rq2 <= rq1; rq3 <= rq2;
	b_wr <= 1'b0;
	b_rd <= 1'b0;
	case (cs)
	2'd0:
		if (rq2 != rq3) begin
			b_addr <= r_addr; b_wdata <= r_wdata;
			if (is_wr) begin b_wr <= 1'b1; cs <= 2'd3; end
			else begin b_rd <= 1'b1; cs <= 2'd1; end
		end
	2'd1: cs <= 2'd2;
	2'd2: begin r_rdata <= b_rdata; cs <= 2'd3; end
	2'd3: begin ack_tog <= rq2; cs <= 2'd0; end
	endcase
end

endmodule
