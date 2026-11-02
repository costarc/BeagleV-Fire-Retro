//
// CP-300 FPGA, BeagleV-Fire: AXI4-Lite slave (aclk, from the fabric interface of the MSS) to the simple
// register bus of bvf_regs (clk, the core clock). One transaction at a time; the two clock domains
// exchange a request toggle and an acknowledge toggle, everything else is held stable.
//
module axil_regbus (
	input             aclk,
	input             aresetn,
	input      [19:0] awaddr, input awvalid, output reg awready,
	input      [31:0] wdata,  input [3:0] wstrb, input wvalid, output reg wready,
	output reg  [1:0] bresp,  output reg bvalid, input bready,
	input      [19:0] araddr, input arvalid, output reg arready,
	output reg [31:0] rdata,  output reg [1:0] rresp, output reg rvalid, input rready,

	input             clk,
	output reg [19:0] b_addr,
	output reg        b_wr,
	output reg [31:0] b_wdata,
	output reg        b_rd,
	input      [31:0] b_rdata
);

// ---------------------------------------------------------------- aclk side
localparam A_IDLE = 2'd0, A_WAIT = 2'd1, A_RESP = 2'd2;
reg [1:0]  as = A_IDLE;
reg        req_tog = 1'b0, is_wr = 1'b0;
reg [19:0] r_addr;
reg [31:0] r_wdata;
reg        ack1 = 1'b0, ack2 = 1'b0;
reg        ack_tog = 1'b0;     // driven in the clk domain
reg [31:0] r_rdata;            // written in the clk domain, read here after the acknowledge

always @(posedge aclk) begin
	ack1 <= ack_tog; ack2 <= ack1;
	if (!aresetn) begin
		as <= A_IDLE; awready <= 1'b0; wready <= 1'b0; arready <= 1'b0;
		bvalid <= 1'b0; rvalid <= 1'b0; req_tog <= 1'b0; bresp <= 2'b00; rresp <= 2'b00;
	end else begin
		awready <= 1'b0; wready <= 1'b0; arready <= 1'b0;
		case (as)
		A_IDLE:
			if (awvalid && wvalid) begin
				awready <= 1'b1; wready <= 1'b1;
				r_addr <= awaddr; r_wdata <= wdata; is_wr <= 1'b1;
				req_tog <= ~req_tog; as <= A_WAIT;
			end else if (arvalid) begin
				arready <= 1'b1;
				r_addr <= araddr; is_wr <= 1'b0;
				req_tog <= ~req_tog; as <= A_WAIT;
			end
		A_WAIT:
			if (ack2 == req_tog) begin
				if (is_wr) bvalid <= 1'b1;
				else begin rdata <= r_rdata; rvalid <= 1'b1; end
				as <= A_RESP;
			end
		A_RESP: begin
			if (bvalid && bready) begin bvalid <= 1'b0; as <= A_IDLE; end
			if (rvalid && rready) begin rvalid <= 1'b0; as <= A_IDLE; end
		end
		default: as <= A_IDLE;
		endcase
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
	2'd1: cs <= 2'd2;                       // read data is valid one clock after rd
	2'd2: begin r_rdata <= b_rdata; cs <= 2'd3; end
	2'd3: begin ack_tog <= rq2; cs <= 2'd0; end
	endcase
end

endmodule
