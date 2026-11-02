// bvf_ddr against a model of the MSS side: an AXI4 slave with a memory and a fixed latency (read 12, write 9 ACLK
// cycles after the request), single beats and bursts. Checks every mode of the probe.
`timescale 1ns/1ps
module tb_ddr;
reg clk = 0, aclk = 0;
always #11.905 clk = ~clk;       // 42 MHz
always #5 aclk = ~aclk;          // 100 MHz, asynchronous to it
reg reset = 1, aresetn = 0;

reg         wr = 0;
reg   [5:0] widx = 0;
reg  [31:0] wdata = 0;
reg   [5:0] ridx = 0;
wire [31:0] rq;

wire  [3:0] awid, arid;
wire [37:0] awaddr, araddr;
wire  [7:0] awlen, arlen;
wire  [2:0] awsize, arsize, awprot, arprot;
wire  [1:0] awburst, arburst;
wire        awlock, arlock;
wire  [3:0] awcache, arcache, awqos, arqos;
wire        awvalid, wvalid, wlast, bready, arvalid, rready;
reg         awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0, rlast = 0;
wire [63:0] wdata_o;
wire  [7:0] wstrb;
reg  [63:0] rdata = 0;
reg   [1:0] bresp = 0, rresp = 0;
reg   [3:0] bid = 0, rid = 0;

bvf_ddr dut (.clk(clk), .reset(reset), .wr(wr), .widx(widx), .wdata(wdata), .ridx(ridx), .rq(rq),
	.aclk(aclk), .aresetn(aresetn),
	.m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst), .m_awlock(awlock), .m_awcache(awcache),
	.m_awprot(awprot), .m_awqos(awqos), .m_awvalid(awvalid), .m_awready(awready), .m_wdata(wdata_o), .m_wstrb(wstrb), .m_wlast(wlast),
	.m_wvalid(wvalid), .m_wready(wready), .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
	.m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst), .m_arlock(arlock), .m_arcache(arcache),
	.m_arprot(arprot), .m_arqos(arqos), .m_arvalid(arvalid), .m_arready(arready), .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp),
	.m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready));

// ---- the slave model
reg [63:0] mem [0:4095];
integer k;
initial for (k = 0; k < 4096; k = k + 1) mem[k] = 64'hDEAD000000000000 | k;
integer rd_lat = 12, wr_lat = 9;
reg stall = 0;
integer reads = 0, writes = 0, beats = 0;

// reads
reg [37:0] r_a; reg [7:0] r_n; integer r_i;
always @(posedge aclk) begin
	arready <= 0;
	if (arvalid && !arready && !rvalid && !stall) begin
		arready <= 1;
	end
	if (arvalid && arready) begin
		r_a = araddr; r_n = arlen; reads = reads + 1;
		repeat (rd_lat) @(posedge aclk);
		for (r_i = 0; r_i <= r_n; r_i = r_i + 1) begin
			rvalid <= 1; rdata <= mem[(r_a >> 3) + r_i]; rlast <= (r_i == r_n); beats = beats + 1;
			@(posedge aclk); while (!rready) @(posedge aclk);
		end
		rvalid <= 0; rlast <= 0;
	end
end
// writes
reg [37:0] w_a; reg got_aw, got_w;
always @(posedge aclk) begin
	awready <= 0; wready <= 0;
	if (awvalid && !got_aw && !awready) awready <= 1;
	if (wvalid && !got_w && !wready) wready <= 1;
	if (awvalid && awready) begin got_aw = 1; w_a = awaddr; end
	if (wvalid && wready) begin got_w = 1; mem[w_a >> 3] <= wdata_o; end
	if (got_aw && got_w) begin
		got_aw = 0; got_w = 0; writes = writes + 1;
		repeat (wr_lat) @(posedge aclk);
		bvalid <= 1;
		@(posedge aclk); while (!bready) @(posedge aclk);
		bvalid <= 0;
	end
end
initial begin got_aw = 0; got_w = 0; end

// ---- the host
integer errors = 0;
task check(input [511:0] what, input [31:0] got, input [31:0] want);
	if (got !== want) begin errors = errors + 1; $display("FAIL %0s: got %0d (%h) want %0d (%h)", what, got, got, want, want); end
	else $display("ok   %0s", what);
endtask
task reg_w(input [5:0] i, input [31:0] v);
	begin @(posedge clk); wr <= 1; widx <= i; wdata <= v; @(posedge clk); wr <= 0; end
endtask
task reg_r(input [5:0] i, output [31:0] v);
	begin @(posedge clk); ridx <= i; @(posedge clk); #1 v = rq; end
endtask
task run(input [2:0] mode, input [31:0] addr, input [31:0] count);
	reg [31:0] v;
	begin
		reg_w(6'h19, addr); reg_w(6'h1A, 0); reg_w(6'h1D, count);
		reg_w(6'h18, {28'd0, 1'b1, mode});
		v = 1;
		while (v[0] == 1) begin repeat (4) @(posedge clk); reg_r(6'h24, v); v = {31'd0, !v[0]}; end
	end
endtask

reg [31:0] v, lo, hi;
initial begin
	repeat (6) @(posedge clk); reset = 0;
	repeat (6) @(posedge aclk); aresetn = 1;
	repeat (6) @(posedge clk);

	// one read
	run(1, 32'h0000_0100, 1);
	reg_r(6'h1E, lo); reg_r(6'h1F, hi);
	check("single read: low word", lo, 32'h0000_0020);
	check("single read: high word", hi, 32'hDEAD_0000);
	reg_r(6'h20, v);  check("single read: latency in ACLK cycles", v, 14 + 0 * 1 + 1 - 1);

	// one write, then the read back
	reg_w(6'h1B, 32'h1234_5678); reg_w(6'h1C, 32'h9ABC_DEF0);
	run(2, 32'h0000_0200, 1);
	check("single write", mem[64][31:0], 32'h1234_5678);
	check("single write: high", mem[64][63:32], 32'h9ABC_DEF0);
	run(1, 32'h0000_0200, 1);
	reg_r(6'h1E, lo); reg_r(6'h1F, hi);
	check("read back", {hi == 32'h9ABC_DEF0, lo == 32'h1234_5678}, 2'b11);

	// 16 reads, one at a time: min = max
	run(3, 32'h0000_0000, 16);
	reg_r(6'h20, v); lo = v; reg_r(6'h21, v); hi = v;
	check("16 reads: min = max", lo == hi, 1);
	reg_r(6'h22, v); check("16 reads: sum = 16 x latency", v, 16 * lo);
	check("16 reads: the slave saw them", reads, 1 + 1 + 16);

	// 8 writes
	reg_w(6'h1B, 32'h0000_0100); reg_w(6'h1C, 32'h0);
	run(4, 32'h0000_0800, 8);
	check("8 writes: first", mem[256][31:0], 32'h100);
	check("8 writes: last", mem[263][31:0], 32'h107);
	reg_r(6'h20, v); check("8 writes: latency in the expected range", v >= 9 && v < 20, 1);

	// 4 bursts of 16 beats
	run(5, 32'h0000_1000, 4);
	check("4 bursts: 64 beats", beats, 1 + 1 + 16 + 64);
	reg_r(6'h23, v); check("4 bursts: total cycles above 4 x (12 + 16)", v >= 4 * 28, 1);

	// write and verify 32 words
	run(6, 32'h0000_2000, 32);
	reg_r(6'h24, v); check("verify: no errors", v[31:4], 0);
	mem[1024 + 5] = 64'h0;                                    // corrupt one word of the area, then verify again over a changed pattern
	run(6, 32'h0000_2000, 32);
	reg_r(6'h24, v); check("verify again: no errors", v[31:4], 0);

	// the clock measure: 2^20 ACLK cycles = 10.48576 ms at 100 MHz = 440402 cycles of 42 MHz
	run(7, 0, 1);
	reg_r(6'h25, v); check("measure: T42 = 2^20 / 100 MHz x 42 MHz (about 440400)", v > 440000 && v < 440800, 1);
	reg_r(6'h23, v); check("measure: total 2^20", v, 1048576);

	// a slave that never answers: the abort frees the probe, a read works afterwards
	stall = 1;
	reg_w(6'h19, 32'h100); reg_w(6'h1A, 0); reg_w(6'h18, 32'h9);       // mode 1, start
	repeat (200) @(posedge clk);
	reg_r(6'h18, v); check("stalled: still busy", v[3], 1);
	reg_w(6'h18, 32'h10);                                              // abort
	repeat (40) @(posedge clk);
	reg_w(6'h18, 32'h0);
	repeat (40) @(posedge clk);
	reg_r(6'h18, v); check("abort: not busy any more", v[3], 0);
	stall = 0;
	run(1, 32'h0000_0100, 1);
	reg_r(6'h1E, lo); check("after the abort a read works", lo, 32'h0000_0020);
	if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
	$finish;
end
initial begin #200000000; $display("FAIL timeout"); $finish; end
endmodule
