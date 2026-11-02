// Testbench for the BeagleV-Fire host side: AXI4-Lite -> axil_regbus -> bvf_regs, with bvf_fb,
// bvf_fdc and bvf_audio, against a mock of the core's video, audio and disk controller service port.
`timescale 1ns/1ps
module tb_bvf;

reg clk = 0, aclk = 0, aresetn = 0;
always #12 clk  = ~clk;      // ~42 MHz
always #4  aclk = ~aclk;     // 125 MHz

// ---------------------------------------------------------------- AXI master
reg [19:0] awaddr, araddr; reg awvalid = 0, wvalid = 0, arvalid = 0, bready = 1, rready = 1;
reg [31:0] wdata;
wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata; wire [1:0] bresp, rresp;

wire [19:0] b_addr; wire b_wr, b_rd; wire [31:0] b_wdata, b_rdata;

axil_regbus bus (.aclk(aclk), .aresetn(aresetn),
	.awaddr(awaddr), .awvalid(awvalid), .awready(awready),
	.wdata(wdata), .wstrb(4'hF), .wvalid(wvalid), .wready(wready),
	.bresp(bresp), .bvalid(bvalid), .bready(bready),
	.araddr(araddr), .arvalid(arvalid), .arready(arready),
	.rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
	.clk(clk), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata), .b_rd(b_rd), .b_rdata(b_rdata));

task axi_write(input [19:0] a, input [31:0] d);
begin
	@(posedge aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
	@(posedge aclk); while (!(awready && wready)) @(posedge aclk);
	awvalid <= 0; wvalid <= 0;
	while (!bvalid) @(posedge aclk);
	@(posedge aclk);
end
endtask

task axi_read(input [19:0] a, output [31:0] d);
begin
	@(posedge aclk); araddr <= a; arvalid <= 1;
	@(posedge aclk); while (!arready) @(posedge aclk);
	arvalid <= 0;
	while (!rvalid) @(posedge aclk);
	d = rdata;
	@(posedge aclk);
end
endtask

// ---------------------------------------------------------------- mock core video: 512 x 192, 4 clk per pixel
function pix(input integer x, input integer y);
	pix = ((x * 7 + y * 3) % 5 == 0) ^ (x == y);
endfunction

reg [1:0] pdiv = 0;
wire pxen = pdiv == 0;
always @(posedge clk) pdiv <= pdiv + 1;

reg screen = 0, ink = 0, vs_n = 1;
integer fx, fy, fr;
initial begin
	fr = 0;
	forever begin
		// frame start pulse
		@(posedge clk); while (!pxen) @(posedge clk);
		vs_n <= 0; repeat (8) begin @(posedge clk); while (!pxen) @(posedge clk); end
		vs_n <= 1; repeat (16) begin @(posedge clk); while (!pxen) @(posedge clk); end
		for (fy = 0; fy < 200; fy = fy + 1) begin
			for (fx = 0; fx < 600; fx = fx + 1) begin
				@(posedge clk); while (!pxen) @(posedge clk);
				screen <= (fx < 512) && (fy < 192);
				ink <= ((fx < 512) && (fy < 192)) ? pix(fx, fy) : 1'b0;
			end
		end
		screen <= 0;
		fr = fr + 1;
	end
end

// ---------------------------------------------------------------- DUT blocks (as in bvf_core)
wire        run, rst_pulse, turbo, wp_all; wire [63:0] keys;
wire [15:0] frame_cnt; wire frame_latest; wire [12:0] fb_addr; wire [31:0] fb_dout;
wire [8:0]  aud_count; wire [31:0] aud_head; wire aud_lost, aud_pop, aud_clr_lost;
wire        rl_we; wire [12:0] rl_waddr;

// mock of the WD1793 / WD1010 service side: request lines, the 512 byte buffer (one clock read latency,
// the servicer owns it while ack is up), the request drops 5 clocks after ack rises, result sampled at the fall
reg         m_rd = 0, m_wr = 0, m_ra = 0, m_dam = 0, m_side = 0, m_hd = 0;
reg   [7:0] m_track = 0, m_trkreg = 0, m_sector = 0; reg [1:0] m_drive = 0;
wire        f_ack, f_found, f_crc, f_dam, f_bwr, req_pending, copy_busy, ack_we, drv_we, sb_we;
wire  [8:0] f_baddr; wire [7:0] f_bdout; reg [7:0] f_bdin = 0;
wire  [3:0] drv_ready, drv_wp, hd_flags;
wire [31:0] req_word, ack_word, drv_word, sb_dout; wire [6:0] sb_addr;
reg   [7:0] mbuf [0:511];
reg   [5:0] m_ackf = 0;
reg   [2:0] m_res = 0; integer m_falls = 0;
always @(posedge clk) begin
	if (f_ack) begin
		if (f_bwr) begin mbuf[f_baddr] <= f_bdout; f_bdin <= f_bdout; end
		else f_bdin <= mbuf[f_baddr];
	end
	m_ackf <= {m_ackf[4:0], f_ack};
	if (m_ackf[5:4] == 2'b01) begin m_rd <= 0; m_wr <= 0; m_ra <= 0; end
	if (m_ackf[5:4] == 2'b10) begin m_res <= {f_dam, f_crc, f_found}; m_falls <= m_falls + 1; end
end

bvf_fdc fdc (.clk(clk), .reset(~run), .flag_reset(1'b0),
	.svc_rd(m_rd), .svc_wr(m_wr), .svc_ra(m_ra), .svc_track(m_track), .svc_trkreg(m_trkreg),
	.svc_sector(m_sector), .svc_dam(m_dam), .svc_drive(m_drive), .svc_side(m_side), .hd_svc(m_hd),
	.ack(f_ack), .res_found(f_found), .res_crc(f_crc), .res_dam(f_dam),
	.buff_addr(f_baddr), .buff_dout(f_bdout), .buff_wr(f_bwr), .buff_din(f_bdin),
	.drv_ready(drv_ready), .drv_wp(drv_wp), .hd_flags(hd_flags),
	.pending(req_pending), .req_word(req_word), .ack_word(ack_word), .drv_word(drv_word), .copy_busy(copy_busy),
	.ack_we(ack_we), .drv_we(drv_we), .wdata(b_wdata), .h_addr(sb_addr), .h_we(sb_we), .h_dout(sb_dout));

reg [8:0] audio = 9'h010;

wire        fbm_we; wire [12:0] fbm_wa, fbm_ra; wire [31:0] fbm_wd, fbm_rq;
bvf_fb #(.BUFS(2)) fb (.clk(clk), .m4(1'b0), .p4_ena(1'b0), .p4_hb(1'b1), .p4_vb(1'b1), .p4_rgb(6'd0), .hold(1'b0), .pxen(pxen), .screen(screen), .ink(ink), .vs_n(vs_n),
	.h_addr(fb_addr), .h_dout(fb_dout), .frame_cnt(frame_cnt), .latest(frame_latest),
	.fbm_we(fbm_we), .fbm_wa(fbm_wa), .fbm_wd(fbm_wd), .fbm_ra(fbm_ra), .fbm_rq(fbm_rq));
bvf_pool pool (.clk(clk), .m2(1'b0), .ram_ra(16'd0), .ram_wa(16'd0), .ram_we(1'b0), .ram_wd(8'd0), .ram_rq(),
	.fb_we(fbm_we), .fb_wa(fbm_wa), .fb_wd(fbm_wd), .fb_ra(fbm_ra), .fb_rq(fbm_rq),
	.cart_we(1'b0), .cart_wa(11'd0), .cart_wd(32'd0), .cart_ra(11'd0), .cart_rq(),
	.v_ena(1'b0), .v_adr(17'd0), .v_we(1'b0), .v_din(8'd0), .v_dout());


bvf_audio #(.CLK_MHZ(42)) aud (.clk(clk), .reset(~run), .audio(audio), .pop(aud_pop), .head(aud_head),
	.count(aud_count), .lost(aud_lost), .clr_lost(aud_clr_lost));

bvf_regs regs (
	.frh_pending(1'b0), .frh_req_word(32'd0), .frh_ack_we(), .frh_we(), .frh_addr(), .frh_dout(32'd0),
	.clk(clk), .reset(1'b0), .addr(b_addr), .wr(b_wr), .wdata(b_wdata), .rd(b_rd), .rdata(b_rdata),
	.run(run), .rst_pulse(rst_pulse), .cold_pulse(), .turbo(turbo), .wp_all(wp_all), .mach(), .fb_hold(), .keys(keys),
	.req_pending(req_pending), .req_is_wr(m_wr), .copy_busy(copy_busy),
	.req_word(req_word), .ack_word(ack_word), .drv_word(drv_word), .ack_we(ack_we), .drv_we(drv_we),
	.frame_cnt(frame_cnt), .frame_latest(frame_latest), .fb_addr(fb_addr), .fb_dout(fb_dout),
	.aud_count(aud_count), .aud_head(aud_head), .aud_lost(aud_lost), .aud_pop(aud_pop), .aud_clr_lost(aud_clr_lost),
	.sb_addr(sb_addr), .sb_we(sb_we), .sb_dout(sb_dout),
	.rl_we(rl_we), .rl_waddr(rl_waddr));

// ROM load capture
integer rl_count = 0; reg [12:0] rl_last; reg [31:0] rl_lastd;
always @(posedge clk) if (rl_we) begin rl_count <= rl_count + 1; rl_last <= rl_waddr; rl_lastd <= b_wdata; end

// ---------------------------------------------------------------- checks
integer errors = 0;
task check(input [255:0] what, input [31:0] got, input [31:0] exp);
begin
	if (got !== exp) begin errors = errors + 1; $display("FAIL %0s: got %h expected %h", what, got, exp); end
	else $display("ok   %0s", what);
end
endtask

reg [31:0] v, v2;
integer i, x, y, bad, frames0, tries;
reg [31:0] w;
reg fl;

initial begin
	repeat (10) @(posedge aclk);
	aresetn = 1;
	repeat (10) @(posedge aclk);

	axi_read(20'h00000, v);              check("ID", v, 32'h43503003);
	axi_write(20'h0000C, 32'hA5A5_0001); axi_write(20'h00010, 32'h8000_0003);
	axi_read(20'h0000C, v);              check("KEYS_LO", v, 32'hA5A5_0001);
	axi_read(20'h00010, v);              check("KEYS_HI", v, 32'h8000_0003);
	check("keys bus", keys[63:0] == 64'h8000_0003_A5A5_0001, 1);
	axi_write(20'h00004, 32'h0000_0005); // run + turbo
	axi_read(20'h00004, v);              check("CTRL", v, 32'h5);

	// ROM load
	axi_write(20'h10000 + 20'h4*20'h123, 32'h11223344);
	check("rl_waddr", rl_last, 13'h123);
	check("rl_data", rl_lastd, 32'h11223344);
	check("rl_count", rl_count, 1);

	// ---- frame: wait for a few frames, then read the latest and compare with the generator
	axi_read(20'h00014, v); frames0 = v[15:0];
	tries = 0;
	while (tries < 2000) begin
		axi_read(20'h00014, v);
		if (v[15:0] >= frames0 + 2) tries = 100000; else begin tries = tries + 1; #20000; end
	end
	// read the newest complete frame while the writer fills the other; copy it and check the counter
	axi_read(20'h00014, v); frames0 = v[15:0]; fl = v[16];
	bad = 0;
	for (y = 0; y < 192; y = y + 1)
		for (x = 0; x < 512; x = x + 32) begin
			axi_read(20'h30000 + 4*((fl ? 4096 : 0) + y*16 + x/32), w);
			for (i = 0; i < 32; i = i + 1)
				if (w[i] !== pix(x+i, y)) bad = bad + 1;
		end
	axi_read(20'h00014, v2);
	$display("frame counter before %0d after %0d, buffer %0d, bad pixels %0d", frames0, v2[15:0], fl, bad);
	// only frames not overwritten during the copy count: the copy can race the writer, so if the counter
	// moved by 2 or more the copy is discarded, like the daemon does
	if (v2[15:0] - frames0 < 2) check("frame pixels", bad, 0);
	else $display("note: frame copy raced the writer (%0d frames), not checked", v2[15:0] - frames0);

	// ---- drive flags
	axi_write(20'h00048, 32'h0000_0E25);  // floppy ready 0,2  wp 1  hd ready 1  hd wp 0,1
	repeat (2) @(posedge clk);
	check("drv_ready", drv_ready, 4'h5);
	check("drv_wp", drv_wp, 4'h2);
	check("hd_flags", hd_flags, 4'hE);
	axi_read(20'h00048, v);              check("DRIVES read back", v, 32'h0E25);
	axi_write(20'h00004, 32'h0);         // core held: the flags stay
	axi_read(20'h00048, v);              check("DRIVES kept while held", v, 32'h0E25);
	axi_write(20'h00004, 32'h5);

	// ---- sector read: the controller wants track 0x11 side 1 sector 3 of drive 1
	axi_read(20'h00008, v);              check("idle: not pending", v[2], 0);
	@(posedge clk); m_track <= 8'h11; m_trkreg <= 8'h11; m_sector <= 8'h03; m_drive <= 2'd1; m_side <= 1; m_rd <= 1;
	@(posedge clk); @(posedge clk);
	check("irq on request", req_pending, 1);
	axi_read(20'h00008, v);              check("status pending", v[3:2], 2'b01);
	axi_read(20'h00040, v);              check("REQ read", v, 32'h03_11_11_19);
	axi_write(20'h00044, 32'h1);         // ACK: the buffer is ours
	repeat (8) @(posedge clk);
	check("request dropped", m_rd, 0);
	check("not pending under ack", req_pending, 0);
	for (i = 0; i < 64; i = i + 1) axi_write(20'h20000 + 4*i, 32'h03020100 + 32'h04040404 * i);
	axi_write(20'h00044, 32'h100);       // ACK = 0, found
	repeat (8) @(posedge clk);
	check("result sampled", m_res, 3'b001);
	bad = 0;
	for (i = 0; i < 256; i = i + 1) if (mbuf[i] !== i[7:0]) bad = bad + 1;
	check("sector data in the buffer", bad, 0);

	// ---- sector write with a deleted data mark: the host reads the buffer back
	for (i = 0; i < 256; i = i + 1) mbuf[i] = 8'hFF - i[7:0];
	@(posedge clk); m_sector <= 8'h07; m_dam <= 1; m_wr <= 1;
	@(posedge clk); @(posedge clk);
	axi_read(20'h00008, v);              check("status write pending", v[3:2], 2'b11);
	axi_read(20'h00040, v);              check("REQ write", v, 32'h07_11_11_5A);
	axi_write(20'h00044, 32'h1);
	tries = 0; v = 32'h80;
	while (v[7] && tries < 100) begin axi_read(20'h00008, v); tries = tries + 1; end
	check("copy finished", v[7], 0);
	bad = 0;
	for (i = 0; i < 64; i = i + 1) begin
		axi_read(20'h20000 + 4*i, w);
		v2[7:0] = 8'hFF - 4*i; v2[15:8] = 8'hFE - 4*i; v2[23:16] = 8'hFD - 4*i; v2[31:24] = 8'hFC - 4*i;
		if (w !== v2) bad = bad + 1;
	end
	check("host reads the sector", bad, 0);
	axi_write(20'h00044, 32'h100);
	repeat (8) @(posedge clk);
	check("write result", m_res, 3'b001);
	@(posedge clk); m_dam <= 0;

	// ---- read address: six bytes, CRC error reported
	@(posedge clk); m_ra <= 1; @(posedge clk); @(posedge clk);
	axi_read(20'h00040, v);              check("REQ read address", v[7:0], 8'h1C);
	axi_write(20'h00044, 32'h1);
	axi_write(20'h20000, 32'h03_01_00_11); axi_write(20'h20004, 32'h0000_BEEF);
	axi_write(20'h00044, 32'h300);       // found + CRC error
	repeat (8) @(posedge clk);
	check("ID field bytes 0-3", {mbuf[3], mbuf[2], mbuf[1], mbuf[0]}, 32'h03010011);
	check("ID field bytes 4-5", {mbuf[5], mbuf[4]}, 16'hBEEF);
	check("read address result", m_res, 3'b011);

	// ---- hard disk request: b7 of REQ
	@(posedge clk); m_hd <= 1; m_drive <= 2'd0; m_side <= 0; m_rd <= 1; @(posedge clk); @(posedge clk);
	axi_read(20'h00040, v);              check("REQ hard disk", v[7:0], 8'h81);
	axi_write(20'h00044, 32'h1); axi_write(20'h00044, 32'h0);
	repeat (8) @(posedge clk);
	check("hard disk not found", m_res, 3'b000);
	check("four requests answered", m_falls, 4);
	@(posedge clk); m_hd <= 0;

	// ---- audio: three changes, popped in order
	axi_write(20'h00018, 32'h1);
	audio <= 9'h011; repeat (200) @(posedge clk);
	audio <= 9'h00F; repeat (200) @(posedge clk);
	axi_read(20'h00018, v);              check("audio count", v[8:0], 2);
	axi_read(20'h0001C, v);              check("audio level 1", v[31:23], 9'h011);
	axi_write(20'h0001C, 32'h0);         // pop
	axi_read(20'h0001C, v);              check("audio level 2", v[31:23], 9'h00F);

	if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
	$finish;
end

initial begin #400000000; $display("FAIL: timeout"); $finish; end

endmodule
