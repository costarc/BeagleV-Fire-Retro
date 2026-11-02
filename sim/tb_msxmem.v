// tb_msxmem.v: bvf_msxmem against an AXI4 slave model (random latencies): Z80 byte reads/writes and the capture writer.
`timescale 1ns/1ps
module tb_msxmem;
reg clk = 0, aclk = 0;
always #11.905 clk = ~clk;
always #4 aclk = ~aclk;
reg reset = 1, aresetn = 0;
reg cpu_start = 0, cpu_we = 0; reg [24:0] cpu_adr = 0; reg [7:0] cpu_wd = 0; wire cpu_ready; wire [7:0] cpu_rd;
reg cap_start = 0; reg [21:0] cap_off = 0; reg [63:0] cap_data = 0; wire cap_busy;

wire [3:0] awid, arid; wire [37:0] awaddr, araddr; wire [7:0] awlen, arlen, wstrb; wire awvalid, wvalid, wlast, bready, arvalid, rready;
wire [63:0] wdata; reg awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0; reg [63:0] rdata = 0;

bvf_msxmem dut (.clk(clk), .reset(reset), .cpu_start(cpu_start), .cpu_we(cpu_we), .cpu_adr(cpu_adr), .cpu_wd(cpu_wd), .cpu_ready(cpu_ready), .cpu_rd(cpu_rd),
	.cap_start(cap_start), .cap_off(cap_off), .cap_data(cap_data), .cap_busy(cap_busy),
	.aclk(aclk), .aresetn(aresetn),
	.m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(), .m_awburst(), .m_awlock(), .m_awcache(), .m_awprot(), .m_awqos(),
	.m_awvalid(awvalid), .m_awready(awready), .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
	.m_bid(4'd0), .m_bresp(2'b00), .m_bvalid(bvalid), .m_bready(bready),
	.m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(), .m_arburst(), .m_arlock(), .m_arcache(), .m_arprot(), .m_arqos(),
	.m_arvalid(arvalid), .m_arready(arready), .m_rid(4'd0), .m_rdata(rdata), .m_rresp(2'b00), .m_rlast(1'b1), .m_rvalid(rvalid), .m_rready(rready));

// slave: 16 MB at offset 0xC8000000 (38 bit address), 64 bit words
reg [63:0] mem [0:(1<<22)-1];
wire [21:0] widx = (awaddr - 38'h00C8000000) >> 3;
wire [21:0] ridx = (araddr - 38'h00C8000000) >> 3;
integer d;
// write
reg [37:0] aw_l; reg aw_have = 0, w_have = 0; reg [63:0] w_l; reg [7:0] s_l;
always @(posedge aclk) begin
	awready <= 0; wready <= 0; bvalid <= bvalid & ~bready;
	if (awvalid && !aw_have && ($random % 3 == 0)) begin awready <= 1; aw_l <= awaddr; aw_have <= 1; end
	if (wvalid && !w_have && ($random % 3 == 0)) begin wready <= 1; w_l <= wdata; s_l <= wstrb; w_have <= 1; end
	if (aw_have && w_have && !bvalid) begin
		for (d = 0; d < 8; d = d + 1) if (s_l[d]) mem[(aw_l - 38'h00C8000000) >> 3][8*d +: 8] = w_l[8*d +: 8];
		aw_have <= 0; w_have <= 0; bvalid <= 1;
	end
end
// read
reg [21:0] r_l; reg r_busy = 0; integer r_wait = 0;
always @(posedge aclk) begin
	arready <= 0;
	if (rvalid && rready) rvalid <= 0;
	if (arvalid && !r_busy && !arready && ($random % 2 == 0)) begin arready <= 1; r_l <= ridx; r_busy <= 1; r_wait <= {$random} % 40; end
	if (r_busy && !arready) begin
		if (r_wait == 0) begin rdata <= mem[r_l]; rvalid <= 1; r_busy <= 0; end else r_wait <= r_wait - 1;
	end
end

integer i, errors = 0, n;
reg [24:0] a; reg [7:0] v;
reg [7:0] refm [0:65535];
task cpu_do(input we, input [24:0] adr, input [7:0] wd);
begin
	@(negedge clk); cpu_we = we; cpu_adr = adr; cpu_wd = wd; cpu_start = 1;
	@(negedge clk); cpu_start = 0;
	@(negedge clk); @(negedge clk);
	while (!cpu_ready) @(negedge clk);
end
endtask

initial begin
	for (i = 0; i < (1<<22); i = i + 1) mem[i] = 64'd0;
	repeat (10) @(negedge clk); reset = 0; aresetn = 1;
	repeat (10) @(negedge clk);
	for (i = 0; i < 65536; i = i + 1) refm[i] = 8'h00;
	for (n = 0; n < 3000; n = n + 1) begin
		a = {$random} % 65536;
		v = $random;
		cpu_do(1'b1, a, v); refm[a] = v;
		a = {$random} % 65536;
		cpu_do(1'b0, a, 8'h00);
		if (cpu_rd !== refm[a]) begin errors = errors + 1; if (errors < 10) $display("read %h: %h vs %h", a, cpu_rd, refm[a]); end
	end
	// the capture writer, with Z80 accesses in between
	for (n = 0; n < 200; n = n + 1) begin
		@(negedge clk); while (cap_busy) @(negedge clk);
		cap_off = n; cap_data = {2{$random}}; cap_start = 1; @(negedge clk); cap_start = 0;
		a = {$random} % 65536; cpu_do(1'b0, a, 8'h00);
		if (cpu_rd !== refm[a]) begin errors = errors + 1; $display("read during capture %h", a); end
		repeat (50) @(negedge clk);
		if (mem[((38'h00C9000000 - 38'h00C8000000) >> 3) + n] !== cap_data) begin errors = errors + 1; if (errors < 10) $display("capture word %0d", n); end
	end
	$display("%0d errors", errors);
	if (errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end
endmodule
