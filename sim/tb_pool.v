// tb_pool.v: bvf_pool against plain arrays. CP mode: RAM 64K x 8, frame buffer 3 x 2K x 32, cartridge 2K x 32 (one clock of read latency).
// The CP-400's ROMs 2 x 2K x 32 (one read address for both); MSX1 mode (mx = 1): the same 8 blocks as the 16 KB VRAM.
`timescale 1ns/1ps
module tb_pool;
reg clk = 0;
always #11.905 clk = ~clk;
reg mx = 0;
reg [15:0] ram_ra = 0, ram_wa = 0; reg ram_we = 0; reg [7:0] ram_wd = 0; wire [7:0] ram_rq;
reg fb_we = 0; reg [12:0] fb_wa = 0, fb_ra = 0; reg [31:0] fb_wd = 0; wire [31:0] fb_rq;
reg cart_we = 0; reg [10:0] cart_wa = 0, cart_ra = 0; reg [31:0] cart_wd = 0; wire [31:0] cart_rq;
reg rom_we = 0; reg [11:0] rom_wa = 0; reg [31:0] rom_wd = 0; reg [10:0] rom_ra = 0; wire [63:0] rom_rq;
reg v_we = 0; reg [13:0] v_wa = 0, v_ra = 0; reg [7:0] v_wd = 0; wire [7:0] v_rq;

bvf_pool dut (.clk(clk), .mx(mx), .ram_ra(ram_ra), .ram_wa(ram_wa), .ram_we(ram_we), .ram_wd(ram_wd), .ram_rq(ram_rq),
	.fb_we(fb_we), .fb_wa(fb_wa), .fb_wd(fb_wd), .fb_ra(fb_ra), .fb_rq(fb_rq),
	.cart_we(cart_we), .cart_wa(cart_wa), .cart_wd(cart_wd), .cart_ra(cart_ra), .cart_rq(cart_rq),
	.rom_we(rom_we), .rom_wa(rom_wa), .rom_wd(rom_wd), .rom_ra(rom_ra), .rom_rq(rom_rq),
	.v_we(v_we), .v_wa(v_wa), .v_wd(v_wd), .v_ra(v_ra), .v_rq(v_rq));

reg [7:0]  ram [0:65535];
reg [31:0] fb  [0:6143];
reg [31:0] ct  [0:2047];
reg [31:0] rm  [0:4095];
reg [7:0]  vr  [0:16383];
integer i, err = 0, n, tick;
reg [15:0] xa; reg [7:0] xd; reg [12:0] fa; reg [10:0] ca; reg [31:0] fd;

task cpcheck;
begin
	mx = 0;
	// RAM: write 5000 random bytes, read them back
	for (i = 0; i < 5000; i = i + 1) begin
		@(negedge clk); ram_wa = $random; ram_wd = $random; ram_we = 1; ram[ram_wa] = ram_wd;
		@(negedge clk); ram_we = 0;
	end
	for (i = 0; i < 5000; i = i + 1) begin
		@(negedge clk); ram_ra = $random;
		@(negedge clk); @(negedge clk);
		if (ram_rq !== ram[ram_ra]) begin err = err + 1; if (err < 10) $display("RAM mismatch %h: %h vs %h", ram_ra, ram_rq, ram[ram_ra]); end
	end
	for (i = 0; i < 3000; i = i + 1) begin
		@(negedge clk); fb_wa = {$random} % 6144; fb_wd = $random; fb_we = 1; fb[fb_wa] = fb_wd;
		@(negedge clk); fb_we = 0;
	end
	for (i = 0; i < 3000; i = i + 1) begin
		@(negedge clk); fb_ra = {$random} % 6144;
		@(negedge clk); @(negedge clk);
		if (fb_rq !== fb[fb_ra]) begin err = err + 1; if (err < 10) $display("FB mismatch %h: %h vs %h", fb_ra, fb_rq, fb[fb_ra]); end
	end
	for (i = 0; i < 1500; i = i + 1) begin
		@(negedge clk); cart_wa = $random; cart_wd = $random; cart_we = 1; ct[cart_wa] = cart_wd;
		@(negedge clk); cart_we = 0;
	end
	for (i = 0; i < 1500; i = i + 1) begin
		@(negedge clk); cart_ra = $random;
		@(negedge clk); @(negedge clk);
		if (cart_rq !== ct[cart_ra]) begin err = err + 1; if (err < 10) $display("CART mismatch %h: %h vs %h", cart_ra, cart_rq, ct[cart_ra]); end
	end
end
endtask

task romcheck;
begin
	for (i = 0; i < 4096; i = i + 1) begin
		@(negedge clk); rom_wa = i; rom_wd = $random; rom_we = 1; rm[i] = rom_wd;
	end
	@(negedge clk); rom_we = 0;
	for (n = 0; n < 3000; n = n + 1) begin
		@(negedge clk); rom_ra = $random;
		@(negedge clk); @(negedge clk);
		if (rom_rq !== {rm[{1'b1, rom_ra}], rm[{1'b0, rom_ra}]}) begin err = err + 1; if (err < 10) $display("ROM mismatch %h: %h", rom_ra, rom_rq); end
	end
end
endtask

// MSX1: the VRAM written through its write port, read back one clock after the address
task vcheck;
begin
	mx = 1;
	for (i = 0; i < 16384; i = i + 1) begin
		@(negedge clk); v_wa = i; v_wd = $random; v_we = 1; vr[i] = v_wd;
	end
	@(negedge clk); v_we = 0;
	for (n = 0; n < 20000; n = n + 1) begin
		@(negedge clk); v_wa = $random; v_wd = $random; v_we = n[0]; if (n[0]) vr[v_wa] = v_wd; v_ra = $random;
		@(negedge clk); v_we = 0;
		if (v_rq !== vr[v_ra]) begin err = err + 1; if (err < 20) $display("VRAM mismatch %h: %h vs %h", v_ra, v_rq, vr[v_ra]); end
	end
	mx = 0;
end
endtask

initial begin
	for (i = 0; i < 65536; i = i + 1) begin ram[i] = 8'hxx; end
	for (i = 0; i < 6144; i = i + 1) fb[i] = 32'hxxxxxxxx;
	for (i = 0; i < 2048; i = i + 1) ct[i] = 32'hxxxxxxxx;
	repeat (4) @(negedge clk);
	cpcheck;
	$display("CP mode: %0d errors", err);
	romcheck;
	$display("CP-400 ROMs: %0d errors in total", err);
	vcheck;
	$display("VRAM test done: %0d errors in total", err);
	if (err == 0) $display("PASS"); else $display("FAIL");
	$finish;
end
endmodule
