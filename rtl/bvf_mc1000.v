//
// BeagleV-Fire multicore: the CCE MC-1000 (Brazil, 1985). The Z80 is the shared one (bvf_core_bus) at 3.58 MHz; the MC6847 is the one
// of Victor Trucco's MC1000 core (../mc1000/mc1000_vdg.vhd), the AY-3-8910 is the OCM's PSG (as the MSX1's). The machine follows
// Trucco's mc1000.vhd (Multicore), without the 80 column card (MC6845).
//
// Memory: the pool's 64 KB RAM (the 64 KB expansion is always there): RAM $0000-$BFFF, the ROM (16 KB, loaded by the host while the
// machine is held, through the ROM load window: 32 bit words, the first byte in bits 31:24) at $C000-$FFFF (the Z80 cannot write
// there). After a reset the ROM is read at every address until the first access to $C000-$FFFF ends. The VRAM (8 KB) is the pool's
// VRAM port (the MSX1's); it is at $8000-$9FFF while port $80 bit 0 is 0, and an access to it waits while the VDG shows the picture.
// I/O: $20-$3F PSG address, $40-$5F PSG read, $60-$7F PSG write, $80-$9F the VDG's mode (b7 A/G, b6 A/S, b5 INT/EXT, b4:2 GM,
// b1 CSS, b0 1 = RAM instead of VRAM at $8000). Keyboard: the PSG's port A drives the rows (register 14), port B reads the columns
// (register 15); the glue answers both (the OCM PSG has the MSX's port directions). INT: a 8.8 us pulse every 3.45 ms (as Trucco's).
// Picture: the VDG's colour index (0..15, 256 x 192 window) for bvf_fb.
//
// Matra Alice (machine 5, alice = 1): the same VDG and VRAM, without the Z80. The MC6803 is emulated on the host, which writes the video
// memory (the Alice's $4000-$57FF, 6 KB, as offset 0..6143) through a window (al_we: word n = 4 bytes, one byte per clock into the VRAM
// port, al_busy while it goes on) and the $BFFF latch through al_mode (b7 DAC = the sound, b6 CSS, b5 A/G, b4 GM0, b3 GM1, b2 GM2 and
// INT/EXT). Per byte of the VRAM: b7 = A/S (semigraphics), b6 = INV (alpha) or colour (semigraphics 4). See alice/README.md.
//
module bvf_mc1000 (
	input         clk,
	input         reset,                 // the machine is held while set
	input  [63:0] keys,                  // 8 rows x 8 columns: keys[8 r + c], 1 = pressed; SHIFT = bit 6, CTRL = bit 7 (column 6 / 7 of every row)
	// the ROM loader
	input         rl_we,
	input  [12:0] rl_waddr,
	input  [31:0] rl_wdata,
	// Matra Alice: the host writes the VRAM and the mode latch
	input         alice,
	input   [7:0] al_mode,
	input         al_we,
	input  [10:0] al_waddr,
	input  [31:0] al_wdata,
	output        al_busy,
	// the shared Z80
	output        z_reset_n,
	output        z_cen,
	output        z_wait_n,
	output        z_int_n,
	output  [7:0] z_di,
	input         z_m1_n,
	input         z_mreq_n,
	input         z_iorq_n,
	input         z_rd_n,
	input         z_wr_n,
	input         z_rfsh_n,
	input  [15:0] z_a,
	input   [7:0] z_do,
	// the RAM in the pool (one clock of read latency)
	output [15:0] ram_ra,
	output [15:0] ram_wa,
	output        ram_we,
	output  [7:0] ram_wd,
	input   [7:0] ram_rq,
	// the VRAM in the pool
	output        v_we,
	output [13:0] v_wa,
	output  [7:0] v_wd,
	output [13:0] v_ra,
	input   [7:0] v_rq,
	// the cassette: EAR on PSG port B bit 7, MIC on PSG port A bit 7 (Victor Trucco's core)
	input         tape_in,
	output  [1:0] tape_out,
	// picture, sound
	output        pix_ena,
	output        pix_hb,
	output        pix_vb,
	output  [3:0] pix_idx,
	output  [8:0] audio
);

// ---------------------------------------------------------------- clock enables: ena21 = 45/88 of 42 MHz, the Z80 and the PSG at
// ena21 / 6 (3.58 MHz), the VDG at 15/44 of 42 MHz (14.318 MHz)
reg   [7:0] acc = 8'd0;
reg   [5:0] acc_v = 6'd0;
reg         ena = 1'b0, cen = 1'b0, ven = 1'b0;
reg   [2:0] div6 = 3'd0;
always @(posedge clk) begin
	if (acc + 8'd45 >= 8'd88) begin acc <= acc + 8'd45 - 8'd88; ena <= 1'b1; end
	else begin acc <= acc + 8'd45; ena <= 1'b0; end
	if (acc_v + 6'd15 >= 6'd44) begin acc_v <= acc_v + 6'd15 - 6'd44; ven <= 1'b1; end
	else begin acc_v <= acc_v + 6'd15; ven <= 1'b0; end
	cen <= 1'b0;
	if (ena) begin
		if (div6 == 3'd5) begin div6 <= 3'd0; cen <= 1'b1; end else div6 <= div6 + 3'd1;
	end
end
wire        psg_en = ena & (div6 == 3'd5);

reg   [1:0] rst_s = 2'b11;
always @(posedge clk) rst_s <= {rst_s[0], reset};
wire        rst = rst_s[1];
assign z_reset_n = ~rst;
assign z_cen = cen;

// INT: 3.448 ms high, 8.82 us low
reg  [17:0] ic = 18'd0;
reg         int_n = 1'b1;
always @(posedge clk) begin
	if (rst) begin ic <= 18'd0; int_n <= 1'b1; end
	else if (int_n) begin if (ic == 18'd144816) begin ic <= 18'd0; int_n <= 1'b0; end else ic <= ic + 18'd1; end
	else begin if (ic == 18'd370) begin ic <= 18'd0; int_n <= 1'b1; end else ic <= ic + 18'd1; end
end
assign z_int_n = int_n;

// ---------------------------------------------------------------- the bus
wire        is_mem = ~z_mreq_n & z_rfsh_n;
wire        is_io  = ~z_iorq_n & z_m1_n;
reg   [7:0] p80 = 8'h00;
wire        rom_area = is_mem & (z_a[15:14] == 2'b11);
reg         rom_c000 = 1'b1, rom_area_d = 1'b0;
always @(posedge clk) begin
	rom_area_d <= rom_area;
	if (rst) rom_c000 <= 1'b1;
	else if (rom_area_d && !rom_area) rom_c000 <= 1'b0;   // the first access to $C000-$FFFF has ended
end
wire        sel_rom  = is_mem & (rom_area | rom_c000);
wire        sel_vram = is_mem & ~sel_rom & (z_a[15:13] == 3'b100) & ~p80[0];

// a write is done when WR_n ends: the address and the data are taken while it is low
wire        wr_act = (is_mem | is_io) & ~z_wr_n;
reg         wr_act_d = 1'b0, cap_mem = 1'b0, cap_vram = 1'b0, cap_io = 1'b0;
reg  [15:0] cap_a = 16'd0;
reg   [7:0] cap_d = 8'd0;
always @(posedge clk) begin
	wr_act_d <= wr_act;
	if (wr_act) begin cap_a <= z_a; cap_d <= z_do; cap_mem <= is_mem & ~sel_vram; cap_vram <= sel_vram; cap_io <= is_io; end
end
wire        wr_end = wr_act_d & ~wr_act;

// port $80
always @(posedge clk) if (rst) p80 <= 8'h00; else if (wr_end && cap_io && cap_a[7:5] == 3'b100) p80 <= cap_d;

// ---------------------------------------------------------------- the PSG: $20 address, $60 write, $40 read (OCM PSG: adr 0 / 1 / 2)
reg         rd_act_d = 1'b0, req = 1'b0, p_wrt = 1'b0;
reg   [1:0] p_sel = 2'd0;
reg   [3:0] psg_reg = 4'd0;
reg   [7:0] p_dbo = 8'd0, rows = 8'hFF;
wire        rd_act = is_io & ~z_rd_n;
always @(posedge clk) begin
	rd_act_d <= rd_act;
	if (rst) begin req <= 1'b0; rows <= 8'hFF; end
	else if (rd_act && !rd_act_d && z_a[7:5] == 3'b010) begin req <= 1'b1; p_sel <= 2'd2; p_wrt <= 1'b0; end
	else if (wr_end && cap_io && (cap_a[7:5] == 3'b001 || cap_a[7:5] == 3'b011)) begin
		req <= 1'b1; p_sel <= (cap_a[7:5] == 3'b001) ? 2'd0 : 2'd1; p_dbo <= cap_d; p_wrt <= 1'b1;
		if (cap_a[7:5] == 3'b001) psg_reg <= cap_d[3:0];
		else if (psg_reg == 4'd14) rows <= cap_d;
	end else if (ena && req) req <= 1'b0;
end
wire  [7:0] psg_dbi, psg_wave;
msx1_psg u_psg (.clk(clk), .ena21(ena), .reset(rst), .clkena(psg_en), .req(req), .wrt(p_wrt), .adr({14'd0, p_sel}), .dbi(psg_dbi),
	.dbo(p_dbo), .wave(psg_wave));
assign tape_out = {1'b0, rows[7]};
assign audio = alice ? {al_mode[7], 8'h00} : {1'b0, psg_wave};

// the keyboard: the columns of the rows that are low; SHIFT and CTRL are in columns 6 and 7 of every row
reg   [7:0] cols;
integer r;
always @(*) begin
	cols = 8'hFF;
	for (r = 0; r < 8; r = r + 1)
		if (!rows[r]) cols = cols & ~{keys[7], keys[6], keys[8 * r +: 6]};
end

// ---------------------------------------------------------------- the VDG
wire [12:0] vdg_a;
wire        vdg_hs_n, vdg_fs_n;
wire        vdg_gate = vdg_hs_n & vdg_fs_n;            // the VDG reads the VRAM
mc1000_vdg vdg (.clock_i(clk), .clock_en_i(ven), .reset_i(rst), .da0_o(), .vr_addr_o(vdg_a), .vr_data_from_i(v_rq), .vr_oe_o(),
	.hs_n_o(vdg_hs_n), .fs_n_o(vdg_fs_n), .an_g_i(alice ? al_mode[5] : p80[7]), .an_s_i(alice ? v_rq[7] : p80[6]), .intn_ext_i(alice ? al_mode[2] : p80[5]),
	.gm_i(alice ? {al_mode[2], al_mode[3], al_mode[4]} : p80[4:2]), .css_i(alice ? al_mode[6] : p80[1]),
	.inv_i(alice ? v_rq[6] : v_rq[7]), .video_col_idx_o(pix_idx), .video_r_o(), .video_g_o(), .video_b_o(), .video_hs_o(), .video_vs_o(),
	.video_hb_o(), .video_vb_o(), .cnt_hor_o(), .cnt_ver_o(), .pix_en_o(pix_ena), .pix_hb_o(pix_hb), .pix_vb_o(pix_vb));
assign v_ra = (sel_vram & ~vdg_gate) ? {1'b0, z_a[12:0]} : {1'b0, vdg_a};

// Alice: the host's word becomes four VRAM byte writes (the first byte in bits 7:0), one per clock
reg   [1:0] al_i = 2'd0;
reg         al_run = 1'b0;
reg  [12:0] al_a = 13'd0;
reg  [31:0] al_d = 32'd0;
always @(posedge clk) begin
	if (al_we && !al_run) begin al_a <= {al_waddr, 2'b00}; al_d <= al_wdata; al_run <= 1'b1; al_i <= 2'd0; end
	else if (al_run) begin
		al_a <= al_a + 13'd1;
		al_d <= {8'h00, al_d[31:8]};
		al_i <= al_i + 2'd1;
		if (al_i == 2'd3) al_run <= 1'b0;
	end
end
assign al_busy = al_run;
assign v_wa = alice ? {1'b0, al_a} : {1'b0, cap_a[12:0]};
assign v_wd = alice ? al_d[7:0] : cap_d;
assign v_we = alice ? al_run : (wr_end & cap_vram);
assign z_wait_n = ~(sel_vram & vdg_gate);

// ---------------------------------------------------------------- the RAM ports, the ROM loader
reg   [1:0] lb = 2'd0;
reg         lbusy = 1'b0;
reg  [11:0] lw_a = 12'd0;
reg  [31:0] lw_d = 32'd0;
always @(posedge clk) begin
	if (rl_we && rst) begin lw_a <= rl_waddr[11:0]; lw_d <= rl_wdata; lbusy <= 1'b1; lb <= 2'd0; end
	else if (lbusy) begin
		lb <= lb + 2'd1;
		lw_d <= {lw_d[23:0], 8'h00};
		if (lb == 2'd3) lbusy <= 1'b0;
	end
end
assign ram_ra = sel_rom ? {2'b11, z_a[13:0]} : z_a;
assign ram_wa = lbusy ? {2'b11, lw_a, lb} : cap_a;
assign ram_wd = lbusy ? lw_d[31:24] : cap_d;
assign ram_we = lbusy | (wr_end & cap_mem & (cap_a[15:14] != 2'b11) & ~rst);

// ---------------------------------------------------------------- read data
assign z_di = is_io ? ((z_a[7:5] == 3'b010) ? ((psg_reg == 4'd15) ? (cols & {tape_in, 7'h7F}) : psg_dbi) : 8'hFF) :
              sel_vram ? v_rq : (is_mem ? ram_rq : 8'hFF);

endmodule
