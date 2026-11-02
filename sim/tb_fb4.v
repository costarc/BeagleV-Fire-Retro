// bvf_fb in CP-400 mode: a mock of the MC6847's VGA output (256 active pixels per line, two VGA lines per picture
// line, vblank around 192 picture lines), the 4 bit colour packing, the frame counter and the hold handshake.
`timescale 1ns/1ps
module tb_fb4;
reg clk = 0;
always #11.905 clk = ~clk;

reg        ena = 0, hb = 1, vb = 1, hold = 0;
reg  [5:0] rgb = 0;
reg [12:0] h_addr = 0;
wire [31:0] h_dout;
wire [15:0] frame_cnt;
wire        latest;

wire        fbm_we; wire [12:0] fbm_wa, fbm_ra; wire [31:0] fbm_wd, fbm_rq;
bvf_fb #(.BUFS(2)) dut (.clk(clk), .m4(1'b1), .pxen(1'b0), .screen(1'b0), .ink(1'b0), .vs_n(1'b1),
	.p4_ena(ena), .p4_hb(hb), .p4_vb(vb), .p4_rgb(rgb), .hold(hold),
	.h_addr(h_addr), .h_dout(h_dout), .frame_cnt(frame_cnt), .latest(latest),
	.fbm_we(fbm_we), .fbm_wa(fbm_wa), .fbm_wd(fbm_wd), .fbm_ra(fbm_ra), .fbm_rq(fbm_rq));
bvf_pool pool (.clk(clk), .m2(1'b0), .ram_ra(16'd0), .ram_wa(16'd0), .ram_we(1'b0), .ram_wd(8'd0), .ram_rq(),
	.fb_we(fbm_we), .fb_wa(fbm_wa), .fb_wd(fbm_wd), .fb_ra(fbm_ra), .fb_rq(fbm_rq),
	.cart_we(1'b0), .cart_wa(11'd0), .cart_wd(32'd0), .cart_ra(11'd0), .cart_rq(),
	.v_ena(1'b0), .v_adr(17'd0), .v_we(1'b0), .v_din(8'd0), .v_dout());


// colour of pixel (x, y) as the 6847's {r,g,b} 2 bit levels, and its expected index
function [5:0] rgb_of(input integer x, input integer y);
	case ((x + y) % 11)
	0: rgb_of = 6'b000000; 1: rgb_of = 6'b001100; 2: rgb_of = 6'b111100; 3: rgb_of = 6'b000011;
	4: rgb_of = 6'b110000; 5: rgb_of = 6'b111111; 6: rgb_of = 6'b001111; 7: rgb_of = 6'b110011;
	8: rgb_of = 6'b111000; 9: rgb_of = 6'b000100; default: rgb_of = 6'b010100;
	endcase
endfunction

integer errors = 0;
task check(input [511:0] what, input [31:0] got, input [31:0] want);
	if (got !== want) begin errors = errors + 1; $display("FAIL %0s: got %h want %h", what, got, want); end
	else $display("ok   %0s", what);
endtask

// one VGA pixel: the enable for one clock, hb/vb stable, the colour the clock after; 3 clocks per pixel
integer ph;
task pixel(input [5:0] c);
	begin
		@(posedge clk); ena <= 1;
		@(posedge clk); ena <= 0; rgb <= c;
		@(posedge clk);
	end
endtask

integer x, y, vl, w, e, f;
task vga_frame;
	begin
		vb <= 1; hb <= 1;
		for (ph = 0; ph < 30; ph = ph + 1) pixel(0);
		vb <= 0;                                       // the picture starts
		for (vl = 0; vl < 384; vl = vl + 1) begin
			y = vl / 2;
			hb <= 1;
			for (ph = 0; ph < 40; ph = ph + 1) pixel(6'b101010);   // blank: colours must be ignored
			hb <= 0;
			for (x = 0; x < 256; x = x + 1) pixel(rgb_of(x, y));
			hb <= 1;
			for (ph = 0; ph < 20; ph = ph + 1) pixel(6'b101010);
		end
		vb <= 1;
		for (ph = 0; ph < 30; ph = ph + 1) pixel(0);
	end
endtask

task rd(input [12:0] a, output [31:0] v);
	begin @(posedge clk); h_addr <= a; @(posedge clk); @(posedge clk); #1 v = h_dout; end
endtask

reg [31:0] v, want;
initial begin
	repeat (10) @(posedge clk);
	vga_frame;
	check("frame counter after one frame", frame_cnt, 1);
	check("latest (nothing being written)", latest, 1);
	// every picture line y, word w: 8 pixels, pixel k in nibble k
	e = 0;
	for (y = 0; y < 192; y = y + 1)
		for (w = 0; w < 32; w = w + 1) begin
			want = 0;
			for (x = 0; x < 8; x = x + 1) begin
				case ((w * 8 + x + y) % 11)
				0: f = 0; 1: f = 1; 2: f = 2; 3: f = 3; 4: f = 4; 5: f = 5; 6: f = 6; 7: f = 7; 8: f = 8; 9: f = 9; default: f = 10;
				endcase
				want = want | (f << (4 * x));
			end
			rd(y * 32 + w, v);
			if (v !== want) begin e = e + 1; if (e < 5) $display("  word y=%0d w=%0d got %h want %h", y, w, v, want); end
		end
	check("6144 words of the picture (errors)", e, 0);

	// hold: a frame started while the host holds the buffer is not written and not counted
	hold = 1;
	rd(0, v); want = v;
	// a different picture while held: shift the colours by one line
	y = 0;
	vga_frame;
	check("held: the frame counter does not move", frame_cnt, 1);
	rd(0, v);
	check("held: the buffer is untouched", v, want);
	hold = 0;
	vga_frame;
	check("released: the next frame counts", frame_cnt, 2);
	if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
	$finish;
end
endmodule
