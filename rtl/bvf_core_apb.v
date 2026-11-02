//
// CP-300 FPGA, BeagleV-Fire: the core behind an APB3 slave on PCLK (the cape port of the gateware
// framework). The 42 MHz core clock comes from a PF_CCC fed by PCLK, see gateware/CAPE/CP300.
//
module bvf_core_apb (
	input         pclk,
	input         presetn,
	input  [31:0] paddr,
	input         psel,
	input         penable,
	input         pwrite,
	input  [31:0] pwdata,
	output [31:0] prdata,
	output        pready,
	output        pslverr,

	input         clk,                 // 42 MHz core clock
	input         pll_locked,
	output        irq,

	// the DDR probe: AXI4 master on FIC0 (ACLK)
	input         aclk,
	input         aresetn,
	output [3:0] m_awid,
	output [37:0] m_awaddr,
	output [7:0] m_awlen,
	output [2:0] m_awsize,
	output [1:0] m_awburst,
	output m_awlock,
	output [3:0] m_awcache,
	output [2:0] m_awprot,
	output [3:0] m_awqos,
	output m_awvalid,
	input  m_awready,
	output [63:0] m_wdata,
	output [7:0] m_wstrb,
	output m_wlast,
	output m_wvalid,
	input  m_wready,
	input  [3:0] m_bid,
	input  [1:0] m_bresp,
	input  m_bvalid,
	output m_bready,
	output [3:0] m_arid,
	output [37:0] m_araddr,
	output [7:0] m_arlen,
	output [2:0] m_arsize,
	output [1:0] m_arburst,
	output m_arlock,
	output [3:0] m_arcache,
	output [2:0] m_arprot,
	output [3:0] m_arqos,
	output m_arvalid,
	input  m_arready,
	input  [3:0] m_rid,
	input  [63:0] m_rdata,
	input  [1:0] m_rresp,
	input  m_rlast,
	input  m_rvalid,
	output m_rready
);

wire [19:0] b_addr;
wire        b_wr, b_rd;
wire [31:0] b_wdata, b_rdata;

apb_regbus #(.ABITS(20), .PAGED(0)) bus (
	.pclk(pclk), .presetn(presetn), .paddr(paddr[19:0]), .psel(psel), .penable(penable), .pwrite(pwrite),
	.pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
	.clk(clk), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata), .b_rd(b_rd), .b_rdata(b_rdata)
);

bvf_core_bus core (.clk(clk), .pll_locked(pll_locked), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata),
	.b_rd(b_rd), .b_rdata(b_rdata), .irq(irq),
	.aclk(aclk), .aresetn(aresetn),
	.m_awid(m_awid),
	.m_awaddr(m_awaddr),
	.m_awlen(m_awlen),
	.m_awsize(m_awsize),
	.m_awburst(m_awburst),
	.m_awlock(m_awlock),
	.m_awcache(m_awcache),
	.m_awprot(m_awprot),
	.m_awqos(m_awqos),
	.m_awvalid(m_awvalid),
	.m_awready(m_awready),
	.m_wdata(m_wdata),
	.m_wstrb(m_wstrb),
	.m_wlast(m_wlast),
	.m_wvalid(m_wvalid),
	.m_wready(m_wready),
	.m_bid(m_bid),
	.m_bresp(m_bresp),
	.m_bvalid(m_bvalid),
	.m_bready(m_bready),
	.m_arid(m_arid),
	.m_araddr(m_araddr),
	.m_arlen(m_arlen),
	.m_arsize(m_arsize),
	.m_arburst(m_arburst),
	.m_arlock(m_arlock),
	.m_arcache(m_arcache),
	.m_arprot(m_arprot),
	.m_arqos(m_arqos),
	.m_arvalid(m_arvalid),
	.m_arready(m_arready),
	.m_rid(m_rid),
	.m_rdata(m_rdata),
	.m_rresp(m_rresp),
	.m_rlast(m_rlast),
	.m_rvalid(m_rvalid),
	.m_rready(m_rready));

endmodule
