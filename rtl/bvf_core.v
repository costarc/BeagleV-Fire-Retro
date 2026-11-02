//
// CP-300 FPGA, BeagleV-Fire: the CP-300 with a host register bus (AXI4-Lite) instead of SD card, PS/2 and
// video connector. The host is the Linux side of the PolarFire SoC (cp300d daemon, see ../host).
//
//   host (AXI4-Lite, aclk) -> axil_regbus -> bvf_core_bus (clk, 42 MHz): the core, bvf_regs, bvf_fdc
//   (disk sector service, answered by the host), frame RAM, audio FIFO. See bvf_core_bus.v.
//
// AXI4-Lite wrapper around bvf_core_bus (the APB variant for the gateware framework is bvf_core_apb.v)
module bvf_core (
	input         clk,
	input         pll_locked,

	input         aclk,
	input         aresetn,
	input  [19:0] s_awaddr, input s_awvalid, output s_awready,
	input  [31:0] s_wdata,  input [3:0] s_wstrb, input s_wvalid, output s_wready,
	output  [1:0] s_bresp,  output s_bvalid, input s_bready,
	input  [19:0] s_araddr, input s_arvalid, output s_arready,
	output [31:0] s_rdata,  output [1:0] s_rresp, output s_rvalid, input s_rready,

	output        irq
);

wire [19:0] b_addr;
wire        b_wr, b_rd;
wire [31:0] b_wdata, b_rdata;

axil_regbus bus (
	.aclk(aclk), .aresetn(aresetn),
	.awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready),
	.wdata(s_wdata), .wstrb(s_wstrb), .wvalid(s_wvalid), .wready(s_wready),
	.bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
	.araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
	.rdata(s_rdata), .rresp(s_rresp), .rvalid(s_rvalid), .rready(s_rready),
	.clk(clk), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata), .b_rd(b_rd), .b_rdata(b_rdata)
);

bvf_core_bus core (.clk(clk), .pll_locked(pll_locked), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata),
	.b_rd(b_rd), .b_rdata(b_rdata), .irq(irq));

endmodule
