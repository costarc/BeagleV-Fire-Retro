// The TMS9918 core (vdp18) in text mode with the picture window and the frame capture (bvf_fb) of the MSX1, as in bvf_msx1.v / bvf_core_bus.v:
// where does the first lit pixel land? The name table is all "A", the pattern of "A" is 11111000 on every row (five lit pixels, one blank),
// so cell 0 is lit at columns 0..4 if the colour index, the blanking and the capture are in step.
//   FIX = 0: pix_idx = the VDP's colour as it is;  FIX = 1: delayed by one clock (what bvf_msx1.v does now)
`timescale 1ns/1ps
module tb_vdp18win;
parameter FIX = 0;
reg clk = 0;
reg rst = 1;
always #11.905 clk = ~clk;                 // 42 MHz
reg [1:0] dv = 0;
always @(posedge clk) dv <= dv + 2'd1;
wire vdp_en = (dv == 2'd0);                // about 10.5 MHz

reg        csw_n = 1;
reg        mode = 0;
reg  [7:0] cd = 0;
reg  [7:0] vram [0:16383];
reg  [7:0] v_rq = 0;
wire [13:0] vram_a;
wire        vram_we;
wire  [7:0] vram_d;
always @(posedge clk) begin
	if (vram_we) vram[vram_a] <= vram_d;
	v_rq <= vram[vram_a];
end

wire        pix_ena;
wire  [8:0] npix, nline;
wire  [3:0] col;
vdp18_core vdp (.clock_i(clk), .clk_en_10m7_i(vdp_en), .por_i(rst), .reset_i(rst),
	.csr_n_i(1'b1), .csw_n_i(csw_n), .mode_i({1'b0, mode}), .int_n_o(),
	.cd_i(cd), .cd_o(),
	.vram_ce_o(), .vram_oe_o(), .vram_we_o(vram_we), .vram_a_o(vram_a), .vram_d_o(vram_d), .vram_d_i(v_rq),
	.vga_en_i(1'b0), .scanline_en_i(1'b0), .cnt_hor_o(), .cnt_ver_o(), .rgb_r_o(col), .rgb_g_o(), .rgb_b_o(),
	.hsync_n_o(), .vsync_n_o(), .ntsc_pal_i(1'b0), .vertfreq_csw_o(), .vertfreq_d_o(),
	.pix_en_o(pix_ena), .num_pix_o(npix), .num_line_o(nline));

task cport(input m, input [7:0] d);        // one write to the control (m = 1) or data (m = 0) port
begin
	repeat (8) @(posedge clk);
	mode = m; cd = d; csw_n = 0;
	repeat (8) @(posedge clk);
	csw_n = 1;
end
endtask
task setreg(input [2:0] r, input [7:0] v);
begin cport(1, v); cport(1, 8'h80 | r); end
endtask

// the window of bvf_msx1.v
wire hb = npix[8] | (npix[7:0] > 8'd255);
wire vb = nline[8] | (nline[7:0] > 8'd191);

// bvf_fb as in bvf_core_bus.v for the MSX1 (p4_direct), the frame RAM as an array
reg  [3:0] idx_q = 0;
always @(posedge clk) idx_q <= col;
wire [3:0] idx = FIX ? idx_q : col;
wire        fbm_we;
wire [12:0] fbm_wa, fbm_ra;
wire [31:0] fbm_wd;
reg  [31:0] fbm [0:8191];
reg  [31:0] fbm_rq = 0;
always @(posedge clk) begin if (fbm_we) fbm[fbm_wa] <= fbm_wd; fbm_rq <= fbm[fbm_ra]; end
bvf_fb #(.BUFS(2)) fb (.clk(clk), .m4(1'b1), .pxen(1'b0), .screen(1'b0), .ink(1'b0), .vs_n(1'b1),
	.p4_ena(pix_ena), .p4_hb(hb), .p4_vb(vb), .p4_rgb({2'b00, idx}), .p4_direct(1'b1), .hold(1'b0),
	.h_addr(13'd0), .h_dout(), .fbm_we(fbm_we), .fbm_wa(fbm_wa), .fbm_wd(fbm_wd), .fbm_ra(fbm_ra), .fbm_rq(fbm_rq),
	.frame_cnt(), .latest());

// line 3 of the picture straight from the VDP (colour and blanking taken at the same pixel enable)
reg hb_p = 1, vb_p = 1;
integer xw = 0, ln = 0;
reg [255:0] linebits, line3;
always @(posedge clk) if (pix_ena) begin
	if (!hb && !vb) begin
		if (hb_p) begin xw = 0; linebits = 256'd0; end
		if (xw < 256) linebits[xw] = (col == 4'd15);
		xw = xw + 1;
	end
	if (!hb_p && hb && !vb) begin if (ln == 3) line3 = linebits; ln = ln + 1; end
	if (vb_p && !vb) ln = 0;
	hb_p <= hb;
	vb_p <= vb;
end

integer i, x;
initial begin
	for (i = 0; i < 16384; i = i + 1) vram[i] = 8'h00;
	for (i = 0; i < 8192; i = i + 1) fbm[i] = 32'd0;
	for (i = 0; i < 960; i = i + 1) vram[i] = 8'h41;               // name table at $0000: "A"
	for (i = 0; i < 8; i = i + 1) vram[16'h0800 + 8'h41 * 8 + i] = 8'hF8;   // pattern table at $0800
	repeat (20) @(posedge clk); rst = 0;
	setreg(0, 8'h00);
	setreg(1, 8'hD0);       // 16K, display on, text mode
	setreg(2, 8'h00);       // name table $0000
	setreg(4, 8'h01);       // pattern table $0800
	setreg(7, 8'hF4);       // white on blue
	#(40_000_000);          // two frames
	$write("VDP line 3:    ");
	for (x = 0; x < 48; x = x + 1) $write("%s", line3[x] ? "#" : ".");
	$write("\n");
	$write("bvf_fb line 3: ");
	for (x = 0; x < 48; x = x + 1) $write("%s", ((fbm[3 * 32 + (x >> 3)] >> (4 * (x & 7))) & 15) == 15 ? "#" : ".");
	$write("\n");
	$display("done (FIX=%0d)", FIX);
	$finish;
end
endmodule
