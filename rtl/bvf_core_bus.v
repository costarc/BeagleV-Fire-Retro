//
// CP-300 FPGA, BeagleV-Fire: the CP-300 with a host register bus instead of SD card, PS/2 and
// video connector. The host is the Linux side of the PolarFire SoC (cp300d daemon, see ../host).
//
//   host (AXI4-Lite, aclk) -> axil_regbus -> bvf_regs (clk, 42 MHz) -> keys, run/reset/turbo,
//                                            ROM load, disk sector service, frame RAM, audio FIFO
//
// The CP-300 core is the one of the Analogue Pocket port (rtl/ht1080z, wd1793, wd1010 ...) with its Z80 outside (ht1080z_bvf.vhd):
// the CP-300, the MSX1 (bvf_msx1), the ZX Spectrum (bvf_zx) and the MC-1000 (bvf_mc1000) share ONE Z80 (T80s), only the selected
// machine runs.
// There is no IO controller: the floppy and hard disk controllers' sector requests go to the host (bvf_fdc),
// which reads the DMK / HDV images itself. The host holds the core in reset (CTRL.run = 0) while it loads
// the two ROMs and the drive flags, then sets run.
//
module bvf_core_bus (
	input         clk,                 // 42 MHz core clock
	input         pll_locked,
	input  [19:0] b_addr,
	input         b_wr,
	input  [31:0] b_wdata,
	input         b_rd,
	output [31:0] b_rdata,
	output        irq,                 // disk request pending (floppy, hard disk, IDE): level

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

// ---------------------------------------------------------------- the CP-300
wire        run, rst_pulse, cold_pulse, turbo, wp_all, fb_hold;
wire        clr_active;                // the RAM is being cleared (power on)
wire [15:0] clr_addr;
wire  [3:0] mach;                     // 0 CP-300, 1 CP-400, 2 MSX1, 3 ZX Spectrum, 4 MC-1000, 5 Alice (bvf_regs CTRL b9:8,5:4)
wire [63:0] keys;
wire [23:0] keys2;
wire        m300       = (mach == 4'd0);
wire        m400       = (mach == 4'd1);
wire        mx         = (mach == 4'd2);      // the MSX1
wire        mz         = (mach == 4'd3);      // the ZX Spectrum
wire        mm         = (mach == 4'd4);      // the MC-1000
wire        ma         = (mach == 4'd5);      // the Matra Alice (MC-10): the 6803 is emulated on the host; the MC-1000's VDG and VRAM
wire        mv         = mm | ma;             // the machines that use the MC-1000's video
wire  [8:0] msx_audio, zx_audio, mc_audio;
// the cassette recorder (bvf_tape) and the MSX1's disk interface (the CP-300's WD1793 on its second bus)
wire        tape_in, tape_ctl_we, tape_play_we, tape_rec_pop, disk_present;
wire [31:0] tape_ctl_rdata, tape_recn, tape_rec_head;
wire  [1:0] c3_cass_out, x1_tape_out, zx_tape_out, mc_tape_out;
wire        c4_cass_out, c4_cass_motor, x1_tape_motor;
wire        x_fd_rst, x_fd_sel, x_fd_rd, x_fd_wr, x_fd_drq, x_fd_intrq, x_fd_side, x_fd_motor;
// the CP-400's floppy controller card (bvf_cocofdc) on the same WD1793
wire  [15:0] c4_dbg_a;
wire  [7:0] k_ctl;
wire        cfdc_present, c4_fdc_cs, c4_fdc_halt, c4_fdc_nmi, k_rst, k_ce, k_sel, k_rd, k_wr, k_side, k_motor;
wire  [7:0] c4_fdc_q, k_din;
wire  [1:0] k_addr, k_drive;
wire  [1:0] x_fd_addr, x_fd_drive;
wire  [7:0] x_fd_din, x_fd_dout;
wire  [1:0] f_drive = m400 ? k_drive : x_fd_drive;
wire        f_motor = m400 ? k_motor : x_fd_motor;
wire  [7:0] al_mode;                  // Alice: the $BFFF latch (bvf_regs 0xA0)
wire        al_we, al_busy;           // Alice: the VRAM window (bvf_regs 0x60000)
wire [10:0] al_waddr;
wire        core_reset = ~run | ~pll_locked | rst_pulse | clr_active | ~m300;      // the CP-300 is held while another machine runs
wire        c4_reset   = ~run | ~pll_locked | rst_pulse | clr_active | ~m400;

wire [15:0] ext_addr;
wire        ext_rd, ext_wr;
wire  [7:0] ext_din;
wire  [7:0] ext_dout;
// Z80 RAM: the full 64 KB, as in the Pocket port. Only 4000-FFFF is needed (48 KB); trimming it saves
// 128 kbit of block RAM if the MPFS025T runs short (check what ht1080z maps below 4000 first).
wire [15:0] c4_ram_a, c4_ram_wa;
wire        c4_ram_we;
wire  [7:0] c4_ram_d;
wire [15:0] x1_ram_ra, x1_ram_wa, zx_ram_ra, zx_ram_wa, mc_ram_ra, mc_ram_wa;
wire        x1_ram_we, zx_ram_we, mc_ram_we;
wire  [7:0] x1_ram_wd, zx_ram_wd, mc_ram_wd;
// one RAM for the machine that runs: a read and a write address
wire [15:0] ram_ra   = m400 ? c4_ram_a : mx ? x1_ram_ra : mz ? zx_ram_ra : mm ? mc_ram_ra : ext_addr;
wire [15:0] ram_wa   = clr_active ? clr_addr : (m400 ? c4_ram_wa : mx ? x1_ram_wa : mz ? zx_ram_wa : mm ? mc_ram_wa : ext_addr);
// power on: the ROM of the Spectrum ($0000-$3FFF) and of the MC-1000 ($C000-$FFFF) stays
wire        clr_we   = clr_active & ~(mz & (clr_addr[15:14] == 2'b00)) & ~(mm & (clr_addr[15:14] == 2'b11));
wire        ram_we   = clr_we | (~clr_active & (m400 ? c4_ram_we : mx ? x1_ram_we : mz ? zx_ram_we : mm ? mc_ram_we : ext_wr));
wire  [7:0] ram_din  = clr_active ? 8'h00 : (m400 ? c4_ram_d : mx ? x1_ram_wd : mz ? zx_ram_wd : mm ? mc_ram_wd : ext_din);

bvf_ramclr ramclr (.clk(clk), .start(cold_pulse), .active(clr_active), .addr(clr_addr));
// the 64 KB RAM, the frame RAM and the CP-400's ROMs are blocks of bvf_pool; with the MSX1 selected the CP-400's ROM blocks are its VRAM
wire        fbm_we, c4_cart_we, c4_rom_we;
wire [12:0] fbm_wa, fbm_ra;
wire [31:0] fbm_wd, fbm_rq;
wire [10:0] c4_cart_wa, c4_cart_ra, c4_rom_ra;
wire [31:0] c4_cart_wd, c4_cart_rq, c4_rom_wd;
wire [11:0] c4_rom_wa;
wire [63:0] c4_rom_rq;
wire        x1_v_we, mc_v_we;             // the VRAM (the CP-400's ROM blocks): the MSX1's or the MC-1000's
wire [13:0] x1_v_wa, x1_v_ra, mc_v_wa, mc_v_ra;
wire  [7:0] x1_v_wd, mc_v_wd, v_rq;
wire        x1_rc_we;                 // the MSX1's ROM cache in the CP-400's cartridge blocks
wire [10:0] x1_rc_wa, x1_rc_ra;
wire [31:0] x1_rc_wd;

bvf_pool pool (
	.clk(clk), .mx(mx | mv),
	.ram_ra(ram_ra), .ram_wa(ram_wa), .ram_we(ram_we), .ram_wd(ram_din), .ram_rq(ext_dout),
	.fb_we(fbm_we), .fb_wa(fbm_wa), .fb_wd(fbm_wd), .fb_ra(fbm_ra), .fb_rq(fbm_rq),
	.cart_we(mx ? x1_rc_we : c4_cart_we), .cart_wa(mx ? x1_rc_wa : c4_cart_wa), .cart_wd(mx ? x1_rc_wd : c4_cart_wd),
	.cart_ra(mx ? x1_rc_ra : c4_cart_ra), .cart_rq(c4_cart_rq),
	.rom_we(c4_rom_we), .rom_wa(c4_rom_wa), .rom_wd(c4_rom_wd), .rom_ra(c4_rom_ra), .rom_rq(c4_rom_rq),
	.v_we(mv ? mc_v_we : x1_v_we), .v_wa(mv ? mc_v_wa : x1_v_wa), .v_wd(mv ? mc_v_wd : x1_v_wd), .v_ra(mv ? mc_v_ra : x1_v_ra), .v_rq(v_rq)
);

// ---------------------------------------------------------------- the shared Z80
wire        z_m1_n, z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_rfsh_n;
wire [15:0] z_a;
wire  [7:0] z_do;
wire        c3_reset_n, c3_cen, c3_wait_n, c3_int_n, c3_nmi_n;
wire  [7:0] c3_di;
wire        x1_reset_n, x1_cen, x1_wait_n, x1_int_n;
wire  [7:0] x1_di;
wire        zx_reset_n, zx_cen, zx_int_n;
wire  [7:0] zx_di;
wire        mc_reset_n, mc_cen, mc_wait_n, mc_int_n;
wire  [7:0] mc_di;
wire        z_reset_n = m300 ? c3_reset_n : mx ? x1_reset_n : mz ? zx_reset_n : mm ? mc_reset_n : 1'b0;   // held while the CP-400 runs
wire        z_cen     = m300 ? c3_cen     : mx ? x1_cen     : mz ? zx_cen     : mm ? mc_cen     : 1'b0;
wire        z_wait_n  = m300 ? c3_wait_n  : mx ? x1_wait_n  : mm ? mc_wait_n  : 1'b1;
wire        z_int_n   = m300 ? c3_int_n   : mx ? x1_int_n   : mz ? zx_int_n   : mm ? mc_int_n   : 1'b1;
wire        z_nmi_n   = m300 ? c3_nmi_n   : 1'b1;
wire  [7:0] z_di      = m300 ? c3_di      : mx ? x1_di      : mz ? zx_di      : mc_di;

T80s z80 (
	.RESET_n(z_reset_n), .CLK(clk), .CEN(z_cen), .WAIT_n(z_wait_n), .INT_n(z_int_n), .NMI_n(z_nmi_n), .BUSRQ_n(1'b1),
	.M1_n(z_m1_n), .MREQ_n(z_mreq_n), .IORQ_n(z_iorq_n), .RD_n(z_rd_n), .WR_n(z_wr_n), .RFSH_n(z_rfsh_n), .HALT_n(), .BUSAK_n(),
	.A(z_a), .DI(z_di), .DO(z_do)
);
// each machine sees the bus only while it is selected (the others see an idle bus)
wire        b3 = ~m300, bx = ~mx, bz = ~mz, bm = ~mm;

wire        vid_screen, vid_ink, vid_pxen;
wire        hs_n, vs_n;
wire  [8:0] audio;

wire  [7:0] fdc_track, fdc_trkreg, fdc_sector;
wire        fdc_rd, fdc_wr, fdc_ra, fdc_dam, fdc_ack, fdc_buff_wr, fdc_side;
wire        fdc_res_found, fdc_res_crc, fdc_res_dam;
wire  [8:0] fdc_buff_addr;
wire  [7:0] fdc_buff_dout, fdc_buff_din;
wire  [1:0] fdc_drive;
wire  [3:0] drv_ready, drv_wp;
wire  [3:0] hd_flags;   // hard disk images mounted / write protected
wire        hd_svc;     // the pending sector request is the hard disk's

wire        rl_we;
wire [12:0] rl_waddr;
wire [31:0] rl_wdata = b_wdata;

wire        sd_nCS, sd_nWE, sd_nCAS, sd_nRAS, sd_dqmh, sd_dqml, sd_cke;
wire [12:0] sd_a;
wire  [1:0] sd_ba;
wire [15:0] sd_dq;
wire [15:0] exp_addr;
// the FreHD command interface (ports C2-C5) on the expansion bus
wire        frh_oe, frh_pending, frh_ack_we, frh_we;
wire  [7:0] frh_dout8, frh_addr;
wire [31:0] frh_req_word, frh_hdout;
wire  [7:0] exp_dout;
wire        exp_in, exp_out;

ht1080z_bvf cp300 (
	.clk42m(clk), .pllLocked(run & pll_locked), .reset(core_reset), .led(),
	.ntsc(1'b1), .turbo(turbo), .ext_keys(keys), .cass_in(tape_in & m300), .cass_out(c3_cass_out),
	.xf_en((mx & disk_present) | (m400 & cfdc_present)), .xf_rst(m400 ? k_rst : x_fd_rst), .xf_ce(m400 ? k_ce : x1_cen), .xf_sel(m400 ? k_sel : x_fd_sel),
	.xf_rd(m400 ? k_rd : x_fd_rd), .xf_wr(m400 ? k_wr : x_fd_wr), .xf_addr(m400 ? k_addr : x_fd_addr), .xf_din(m400 ? k_din : x_fd_din),
	.xf_dout(x_fd_dout), .xf_drq(x_fd_drq), .xf_intrq(x_fd_intrq), .xf_drive(f_drive), .xf_side(m400 ? k_side : x_fd_side),
	.xf_ready(f_motor & drv_ready[f_drive]), .xf_wp(drv_wp[f_drive]), .xf_sec512(mx),
	.fdc_svc_rd(fdc_rd), .fdc_svc_wr(fdc_wr), .fdc_svc_ra(fdc_ra), .fdc_svc_track(fdc_track),
	.fdc_svc_trkreg(fdc_trkreg), .fdc_svc_sector(fdc_sector), .fdc_svc_dam(fdc_dam),
	.fdc_svc_ack(fdc_ack), .fdc_res_found(fdc_res_found), .fdc_res_crc(fdc_res_crc),
	.fdc_res_dam(fdc_res_dam), .fdc_buff_addr(fdc_buff_addr), .fdc_buff_dout(fdc_buff_dout),
	.fdc_buff_din(fdc_buff_din), .fdc_buff_wr(fdc_buff_wr), .fdc_drive(fdc_drive),
	.fdc_side(fdc_side), .drv_ready(drv_ready), .drv_wp(drv_wp),
	.hd_flags(hd_flags),
	.hd_svc(hd_svc),
	.ps2clk(1'b1), .ps2dat(1'b1),
	.ht_rgb(), .hs(hs_n), .vs(vs_n), .hb(), .vb(),
	.vid_screen(vid_screen), .vid_ink(vid_ink), .vid_pxen(vid_pxen),
	.vid_ink_rgb(), .vid_paper_rgb(), .vid_border_rgb(),
	.audiomix(audio),
	.dn_go(1'b0), .dn_wr(1'b0), .dn_addr(25'd0), .dn_data(8'd0), .dn_idx(5'd0),
	.exp_addr(exp_addr), .exp_din(frh_dout8), .exp_dout(exp_dout), .exp_in(exp_in), .exp_out(exp_out), .exp_oe(frh_oe & m300),
	.ext_ram_addr(ext_addr), .ext_ram_rd(ext_rd), .ext_ram_wr(ext_wr), .ext_ram_din(ext_din),
	.ext_ram_dout(ext_dout), .ext_ram_wait(1'b0),
	.SDRAM_nCS(sd_nCS), .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_DQMH(sd_dqmh), .SDRAM_DQML(sd_dqml),
	.SDRAM_nWE(sd_nWE), .SDRAM_nCAS(sd_nCAS), .SDRAM_nRAS(sd_nRAS), .SDRAM_BA(sd_ba), .SDRAM_CKE(sd_cke),
	.rl_clk(clk), .rl_we(rl_we & m300), .rl_waddr(rl_waddr), .rl_wdata(rl_wdata),
	.xcpu_reset_n(c3_reset_n), .xcpu_cen(c3_cen), .xcpu_wait_n(c3_wait_n), .xcpu_int_n(c3_int_n), .xcpu_nmi_n(c3_nmi_n), .xcpu_di(c3_di),
	.xcpu_m1_n(z_m1_n | b3), .xcpu_mreq_n(z_mreq_n | b3), .xcpu_iorq_n(z_iorq_n | b3), .xcpu_rd_n(z_rd_n | b3), .xcpu_wr_n(z_wr_n | b3),
	.xcpu_a(z_a), .xcpu_do(z_do)
);

// ---------------------------------------------------------------- the CP-400 (CoCo 2)
wire        c4_cap_ena, c4_cap_hb, c4_cap_vb, c4_fs_n;
wire  [5:0] c4_cap_rgb;
wire  [8:0] c4_audio;
// the CP-400's hard disk: the CPU bus of the machine, the IDE registers, the host's window
wire        ide_cs, ide_cyc_end, ide_rw;
wire  [3:0] ide_a;
wire  [7:0] ide_din, ide_q;
wire        ide_pending, ide_ack_we, ide_we, ide_present, cart_present;
wire [31:0] ide_req_word, ide_lba_word, ide_ack_word, ide_hdout;
wire  [6:0] ide_addr;

`ifndef BVF_NO_CP400
cp400_core cp400 (
	.clk(clk), .reset(c4_reset), .keys(keys),
	.rl_we(rl_we & m400), .rl_waddr(rl_waddr), .rl_wdata(rl_wdata),
	.ram_a(c4_ram_a), .ram_we(c4_ram_we), .ram_wa(c4_ram_wa), .ram_d(c4_ram_d), .ram_q(ext_dout),
	.cap_ena(c4_cap_ena), .cap_hb(c4_cap_hb), .cap_vb(c4_cap_vb), .cap_rgb(c4_cap_rgb), .cap_fs_n(c4_fs_n),
	.audio(c4_audio), .cass_in(tape_in & m400), .cass_out(c4_cass_out), .cass_motor(c4_cass_motor),
	.cart_en(cart_present),
	.cart_we(c4_cart_we), .cart_wa(c4_cart_wa), .cart_wd(c4_cart_wd), .cart_ra(c4_cart_ra), .cart_rq(c4_cart_rq),
	.rom_we(c4_rom_we), .rom_wa(c4_rom_wa), .rom_wd(c4_rom_wd), .rom_ra(c4_rom_ra), .rom_rq(c4_rom_rq),
	.ide_cs(ide_cs), .ide_cyc_end(ide_cyc_end), .ide_rw(ide_rw), .ide_a(ide_a), .ide_d(ide_din), .ide_q(ide_q),
	.dbg_a(c4_dbg_a), .fdc_cs(c4_fdc_cs), .fdc_q(c4_fdc_q), .fdc_halt(c4_fdc_halt), .fdc_nmi(c4_fdc_nmi)
);

bvf_cocofdc cfdc (
	.clk(clk), .reset(c4_reset), .present(cfdc_present), .cs(c4_fdc_cs), .rw(ide_rw), .a(ide_a), .d(ide_din), .cyc_end(ide_cyc_end),
	.q(c4_fdc_q), .halt(c4_fdc_halt), .nmi(c4_fdc_nmi),
	.xf_rst(k_rst), .xf_ce(k_ce), .xf_sel(k_sel), .xf_rd(k_rd), .xf_wr(k_wr), .xf_addr(k_addr), .xf_din(k_din),
	.xf_dout(x_fd_dout), .xf_drq(x_fd_drq), .xf_intrq(x_fd_intrq), .xf_drive(k_drive), .xf_side(k_side), .motor(k_motor), .dbg_ctl(k_ctl)
);

bvf_ide ide (
	.clk(clk), .reset(c4_reset), .present(ide_present),
	.cs(ide_cs), .cyc_end(ide_cyc_end), .rw(ide_rw), .a(ide_a), .din(ide_din), .dout(ide_q),
	.pending(ide_pending), .req_word(ide_req_word), .lba_word(ide_lba_word), .ack_word(ide_ack_word),
	.ack_we(ide_ack_we), .wdata(b_wdata), .h_addr(ide_addr), .h_we(ide_we), .h_dout(ide_hdout)
);
`else
// gateware without the CP-400
assign c4_ram_a = 16'd0, c4_ram_wa = 16'd0, c4_ram_we = 1'b0, c4_ram_d = 8'd0;
assign c4_cap_ena = 1'b0, c4_cap_hb = 1'b1, c4_cap_vb = 1'b1, c4_cap_rgb = 6'd0, c4_fs_n = 1'b1, c4_audio = 9'd0;
assign c4_cass_out = 1'b0, c4_cass_motor = 1'b0;
assign c4_dbg_a = 16'd0, k_ctl = 8'd0;
assign c4_fdc_cs = 1'b0, c4_fdc_q = 8'hFF, c4_fdc_halt = 1'b0, c4_fdc_nmi = 1'b0;
assign k_rst = 1'b1, k_ce = 1'b0, k_sel = 1'b0, k_rd = 1'b0, k_wr = 1'b0, k_addr = 2'd0, k_din = 8'd0, k_drive = 2'd0, k_side = 1'b0, k_motor = 1'b0;
assign c4_cart_we = 1'b0, c4_cart_wa = 11'd0, c4_cart_wd = 32'd0, c4_cart_ra = 11'd0;
assign c4_rom_we = 1'b0, c4_rom_wa = 12'd0, c4_rom_wd = 32'd0, c4_rom_ra = 11'd0;
assign ide_pending = 1'b0, ide_req_word = 32'd0, ide_lba_word = 32'd0, ide_ack_word = 32'd0, ide_hdout = 32'd0;
`endif

// ---------------------------------------------------------------- disk service: answered by the host
wire        req_pending, copy_busy, ack_we, drv_we, sb_we;
wire [31:0] req_word, ack_word, drv_word, sb_dout;
wire  [6:0] sb_addr;

bvf_fdc fdc (
	.clk(clk), .reset(~run | ~pll_locked | clr_active), .flag_reset(~pll_locked),
	.svc_rd(fdc_rd), .svc_wr(fdc_wr), .svc_ra(fdc_ra), .svc_track(fdc_track), .svc_trkreg(fdc_trkreg),
	.svc_sector(fdc_sector), .svc_dam(fdc_dam), .svc_drive(fdc_drive), .svc_side(fdc_side), .hd_svc(hd_svc),
	.ack(fdc_ack), .res_found(fdc_res_found), .res_crc(fdc_res_crc), .res_dam(fdc_res_dam),
	.buff_addr(fdc_buff_addr), .buff_dout(fdc_buff_dout), .buff_wr(fdc_buff_wr), .buff_din(fdc_buff_din),
	.drv_ready(drv_ready), .drv_wp(drv_wp), .hd_flags(hd_flags),
	.pending(req_pending), .req_word(req_word), .ack_word(ack_word), .drv_word(drv_word), .copy_busy(copy_busy),
	.ack_we(ack_we), .drv_we(drv_we), .wdata(b_wdata), .h_addr(sb_addr), .h_we(sb_we), .h_dout(sb_dout)
);

// ---------------------------------------------------------------- frame capture and audio
wire [15:0] frame_cnt;
wire        frame_latest;
wire [12:0] fb_addr;
wire [31:0] fb_dout;

wire        x1_pix_ena, x1_pix_hb, x1_pix_vb, zx_pix_ena, zx_pix_hb, zx_pix_vb, mc_pix_ena, mc_pix_hb, mc_pix_vb;
wire  [3:0] x1_pix_idx, zx_pix_idx, mc_pix_idx;
wire  [2:0] zx_border;
wire [31:0] zx_dbg;
bvf_fb #(.BUFS(2)) fb (
	.clk(clk), .m4(~m300), .pxen(vid_pxen), .screen(vid_screen), .ink(vid_ink), .vs_n(vs_n),
	.p4_ena(mx ? x1_pix_ena : mz ? zx_pix_ena : mv ? mc_pix_ena : c4_cap_ena),
	.p4_hb(mx ? x1_pix_hb : mz ? zx_pix_hb : mv ? mc_pix_hb : c4_cap_hb),
	.p4_vb(mx ? x1_pix_vb : mz ? zx_pix_vb : mv ? mc_pix_vb : c4_cap_vb),
	.p4_rgb(mx ? {2'b00, x1_pix_idx} : mz ? {2'b00, zx_pix_idx} : mv ? {2'b00, mc_pix_idx} : c4_cap_rgb),
	.p4_direct(mx | mz | mv), .hold(fb_hold),
	.h_addr(fb_addr), .h_dout(fb_dout), .frame_cnt(frame_cnt), .latest(frame_latest),
	.fbm_we(fbm_we), .fbm_wa(fbm_wa), .fbm_wd(fbm_wd), .fbm_ra(fbm_ra), .fbm_rq(fbm_rq)
);

wire [8:0]  aud_count;
wire [31:0] aud_head;
wire        aud_lost, aud_pop, aud_clr_lost;

bvf_audio #(.CLK_MHZ(42)) aud (
	.clk(clk), .reset(~run), .audio(mx ? msx_audio : mz ? zx_audio : mv ? mc_audio : (m400 ? c4_audio : audio)), .pop(aud_pop), .head(aud_head), .count(aud_count),
	.lost(aud_lost), .clr_lost(aud_clr_lost)
);

// ---------------------------------------------------------------- AXI master: the probe (host) or the MSX1 (own = MSX1 running)
wire own = run & mx;
reg [1:0] own_s = 2'b00;
always @(posedge aclk) own_s <= {own_s[0], own};
wire own_a = own_s[1];
wire [3:0] d_awid, x_awid;
wire [37:0] d_awaddr, x_awaddr;
wire [7:0] d_awlen, x_awlen;
wire [2:0] d_awsize, x_awsize;
wire [1:0] d_awburst, x_awburst;
wire  d_awlock, x_awlock;
wire [3:0] d_awcache, x_awcache;
wire [2:0] d_awprot, x_awprot;
wire [3:0] d_awqos, x_awqos;
wire  d_awvalid, x_awvalid;
wire [63:0] d_wdata, x_wdata;
wire [7:0] d_wstrb, x_wstrb;
wire  d_wlast, x_wlast;
wire  d_wvalid, x_wvalid;
wire  d_bready, x_bready;
wire [3:0] d_arid, x_arid;
wire [37:0] d_araddr, x_araddr;
wire [7:0] d_arlen, x_arlen;
wire [2:0] d_arsize, x_arsize;
wire [1:0] d_arburst, x_arburst;
wire  d_arlock, x_arlock;
wire [3:0] d_arcache, x_arcache;
wire [2:0] d_arprot, x_arprot;
wire [3:0] d_arqos, x_arqos;
wire  d_arvalid, x_arvalid;
wire  d_rready, x_rready;

// ---------------------------------------------------------------- the DDR probe
wire        ddr_wr;
wire  [5:0] ddr_widx, ddr_ridx;
wire [31:0] ddr_rq;

bvf_ddr ddr (
	.clk(clk), .reset(~pll_locked), .wr(ddr_wr), .widx(ddr_widx), .wdata(b_wdata), .ridx(ddr_ridx), .rq(ddr_rq),
	.aclk(aclk), .aresetn(aresetn),
	.m_awid(d_awid),
	.m_awaddr(d_awaddr),
	.m_awlen(d_awlen),
	.m_awsize(d_awsize),
	.m_awburst(d_awburst),
	.m_awlock(d_awlock),
	.m_awcache(d_awcache),
	.m_awprot(d_awprot),
	.m_awqos(d_awqos),
	.m_awvalid(d_awvalid),
	.m_awready(m_awready & ~own_a),
	.m_wdata(d_wdata),
	.m_wstrb(d_wstrb),
	.m_wlast(d_wlast),
	.m_wvalid(d_wvalid),
	.m_wready(m_wready & ~own_a),
	.m_bid(m_bid),
	.m_bresp(m_bresp),
	.m_bvalid(m_bvalid & ~own_a),
	.m_bready(d_bready),
	.m_arid(d_arid),
	.m_araddr(d_araddr),
	.m_arlen(d_arlen),
	.m_arsize(d_arsize),
	.m_arburst(d_arburst),
	.m_arlock(d_arlock),
	.m_arcache(d_arcache),
	.m_arprot(d_arprot),
	.m_arqos(d_arqos),
	.m_arvalid(d_arvalid),
	.m_arready(m_arready & ~own_a),
	.m_rid(m_rid),
	.m_rdata(m_rdata),
	.m_rresp(m_rresp),
	.m_rlast(m_rlast),
	.m_rvalid(m_rvalid & ~own_a),
	.m_rready(d_rready)
);


assign m_awid = own_a ? x_awid : d_awid;
assign m_awaddr = own_a ? x_awaddr : d_awaddr;
assign m_awlen = own_a ? x_awlen : d_awlen;
assign m_awsize = own_a ? x_awsize : d_awsize;
assign m_awburst = own_a ? x_awburst : d_awburst;
assign m_awlock = own_a ? x_awlock : d_awlock;
assign m_awcache = own_a ? x_awcache : d_awcache;
assign m_awprot = own_a ? x_awprot : d_awprot;
assign m_awqos = own_a ? x_awqos : d_awqos;
assign m_awvalid = own_a ? x_awvalid : d_awvalid;
assign m_wdata = own_a ? x_wdata : d_wdata;
assign m_wstrb = own_a ? x_wstrb : d_wstrb;
assign m_wlast = own_a ? x_wlast : d_wlast;
assign m_wvalid = own_a ? x_wvalid : d_wvalid;
assign m_bready = own_a ? x_bready : d_bready;
assign m_arid = own_a ? x_arid : d_arid;
assign m_araddr = own_a ? x_araddr : d_araddr;
assign m_arlen = own_a ? x_arlen : d_arlen;
assign m_arsize = own_a ? x_arsize : d_arsize;
assign m_arburst = own_a ? x_arburst : d_arburst;
assign m_arlock = own_a ? x_arlock : d_arlock;
assign m_arcache = own_a ? x_arcache : d_arcache;
assign m_arprot = own_a ? x_arprot : d_arprot;
assign m_arqos = own_a ? x_arqos : d_arqos;
assign m_arvalid = own_a ? x_arvalid : d_arvalid;
assign m_rready = own_a ? x_rready : d_rready;

// ---------------------------------------------------------------- the MSX1 and the ZX Spectrum (on the shared Z80)
bvf_msx1 msx (
	.clk(clk), .reset(~run | ~pll_locked | rst_pulse | clr_active | ~mx), .keys({keys2, keys}), .cart_en(cart_present),
	.z_reset_n(x1_reset_n), .z_cen(x1_cen), .z_wait_n(x1_wait_n), .z_int_n(x1_int_n), .z_di(x1_di),
	.z_m1_n(z_m1_n | bx), .z_mreq_n(z_mreq_n | bx), .z_iorq_n(z_iorq_n | bx), .z_rd_n(z_rd_n | bx), .z_wr_n(z_wr_n | bx),
	.z_rfsh_n(z_rfsh_n), .z_a(z_a), .z_do(z_do),
	.ram_ra(x1_ram_ra), .ram_wa(x1_ram_wa), .ram_we(x1_ram_we), .ram_wd(x1_ram_wd), .ram_rq(ext_dout),
	.v_we(x1_v_we), .v_wa(x1_v_wa), .v_wd(x1_v_wd), .v_ra(x1_v_ra), .v_rq(v_rq),
	.rc_we(x1_rc_we), .rc_wa(x1_rc_wa), .rc_wd(x1_rc_wd), .rc_ra(x1_rc_ra), .rc_rq(c4_cart_rq),
	.pix_ena(x1_pix_ena), .pix_hb(x1_pix_hb), .pix_vb(x1_pix_vb), .pix_idx(x1_pix_idx), .audio(msx_audio),
	.tape_in(tape_in & mx), .tape_out(x1_tape_out), .tape_motor(x1_tape_motor),
	.disk_en(disk_present), .fd_rst(x_fd_rst), .fd_sel(x_fd_sel), .fd_rd(x_fd_rd), .fd_wr(x_fd_wr), .fd_addr(x_fd_addr), .fd_din(x_fd_din),
	.fd_dout(x_fd_dout), .fd_drq(x_fd_drq), .fd_intrq(x_fd_intrq), .fd_drive(x_fd_drive), .fd_side(x_fd_side), .fd_motor(x_fd_motor),
	.own(own), .aclk(aclk), .aresetn(aresetn),
	.m_awid(x_awid),
	.m_awaddr(x_awaddr),
	.m_awlen(x_awlen),
	.m_awsize(x_awsize),
	.m_awburst(x_awburst),
	.m_awlock(x_awlock),
	.m_awcache(x_awcache),
	.m_awprot(x_awprot),
	.m_awqos(x_awqos),
	.m_awvalid(x_awvalid),
	.m_wdata(x_wdata),
	.m_wstrb(x_wstrb),
	.m_wlast(x_wlast),
	.m_wvalid(x_wvalid),
	.m_bready(x_bready),
	.m_arid(x_arid),
	.m_araddr(x_araddr),
	.m_arlen(x_arlen),
	.m_arsize(x_arsize),
	.m_arburst(x_arburst),
	.m_arlock(x_arlock),
	.m_arcache(x_arcache),
	.m_arprot(x_arprot),
	.m_arqos(x_arqos),
	.m_arvalid(x_arvalid),
	.m_rready(x_rready),
	.m_awready(m_awready & own_a),
	.m_wready(m_wready & own_a),
	.m_bid(m_bid),
	.m_bresp(m_bresp),
	.m_bvalid(m_bvalid & own_a),
	.m_arready(m_arready & own_a),
	.m_rid(m_rid),
	.m_rdata(m_rdata),
	.m_rresp(m_rresp),
	.m_rlast(m_rlast),
	.m_rvalid(m_rvalid & own_a)
);

bvf_zx zx (
	.clk(clk), .reset(~run | ~pll_locked | rst_pulse | clr_active | ~mz), .keys(keys),
	.rl_we(rl_we & mz), .rl_waddr(rl_waddr), .rl_wdata(rl_wdata),
	.z_reset_n(zx_reset_n), .z_cen(zx_cen), .z_int_n(zx_int_n), .z_di(zx_di),
	.z_m1_n(z_m1_n | bz), .z_mreq_n(z_mreq_n | bz), .z_iorq_n(z_iorq_n | bz), .z_rd_n(z_rd_n | bz), .z_wr_n(z_wr_n | bz),
	.z_rfsh_n(z_rfsh_n), .z_a(z_a), .z_do(z_do),
	.ram_ra(zx_ram_ra), .ram_wa(zx_ram_wa), .ram_we(zx_ram_we), .ram_wd(zx_ram_wd), .ram_rq(ext_dout),
	.pix_ena(zx_pix_ena), .pix_hb(zx_pix_hb), .pix_vb(zx_pix_vb), .pix_idx(zx_pix_idx), .border(zx_border), .audio(zx_audio), .dbg(zx_dbg), .tape_in(tape_in & mz), .tape_out(zx_tape_out)
);

bvf_mc1000 mc (
	.clk(clk), .reset(~run | ~pll_locked | rst_pulse | clr_active | ~mv), .keys(keys),
	.rl_we(rl_we & mm), .rl_waddr(rl_waddr), .rl_wdata(rl_wdata),
	.alice(ma), .al_mode(al_mode), .al_we(al_we & ma), .al_waddr(al_waddr), .al_wdata(rl_wdata), .al_busy(al_busy),
	.z_reset_n(mc_reset_n), .z_cen(mc_cen), .z_wait_n(mc_wait_n), .z_int_n(mc_int_n), .z_di(mc_di),
	.z_m1_n(z_m1_n | bm), .z_mreq_n(z_mreq_n | bm), .z_iorq_n(z_iorq_n | bm), .z_rd_n(z_rd_n | bm), .z_wr_n(z_wr_n | bm),
	.z_rfsh_n(z_rfsh_n), .z_a(z_a), .z_do(z_do),
	.ram_ra(mc_ram_ra), .ram_wa(mc_ram_wa), .ram_we(mc_ram_we), .ram_wd(mc_ram_wd), .ram_rq(ext_dout),
	.v_we(mc_v_we), .v_wa(mc_v_wa), .v_wd(mc_v_wd), .v_ra(mc_v_ra), .v_rq(v_rq),
	.pix_ena(mc_pix_ena), .pix_hb(mc_pix_hb), .pix_vb(mc_pix_vb), .pix_idx(mc_pix_idx), .audio(mc_audio), .tape_in(mm ? tape_in : 1'b1), .tape_out(mc_tape_out)
);


// ---------------------------------------------------------------- the FreHD command interface
bvf_frehd frehd (
	.clk(clk), .reset(core_reset), .a(exp_addr[7:0]), .io_rd(exp_in), .io_wr(exp_out), .din(exp_dout),
	.dout(frh_dout8), .oe(frh_oe), .pending(frh_pending), .req_word(frh_req_word),
	.ack_we(frh_ack_we), .ack_wdata(b_wdata), .h_addr(frh_addr), .h_we(frh_we), .h_wdata(b_wdata), .h_dout(frh_hdout)
);

// ---------------------------------------------------------------- the cassette recorder: one for the machine that runs
wire  [1:0] tape_out   = m300 ? c3_cass_out : m400 ? {1'b0, c4_cass_out} : mx ? x1_tape_out : mz ? zx_tape_out : mm ? mc_tape_out : 2'b00;
wire        tape_motor = m400 ? c4_cass_motor : mx ? x1_tape_motor : 1'b1;      // the others have no motor line: the tape runs while PLAY is on
bvf_tape tape (
	.clk(clk), .reset(~pll_locked), .ctl_we(tape_ctl_we), .ctl_wdata(b_wdata), .ctl_rdata(tape_ctl_rdata),
	.play_we(tape_play_we), .play_wdata(b_wdata), .recn_rdata(tape_recn), .rec_pop(tape_rec_pop), .rec_head(tape_rec_head),
	.motor(tape_motor), .tape_out(tape_out), .tape_in(tape_in)
);

// ---------------------------------------------------------------- registers
bvf_regs regs (
	.clk(clk), .reset(~pll_locked), .addr(b_addr), .wr(b_wr), .wdata(b_wdata), .rd(b_rd), .rdata(b_rdata),
	.run(run), .rst_pulse(rst_pulse), .cold_pulse(cold_pulse), .turbo(turbo), .wp_all(wp_all), .tape_ctl_we(tape_ctl_we), .tape_play_we(tape_play_we), .tape_rec_pop(tape_rec_pop), .tape_ctl_rdata(tape_ctl_rdata), .tape_recn(tape_recn), .tape_rec_head(tape_rec_head), .disk_present(disk_present), .cfdc_present(cfdc_present),
	.dbg(m400 ? {k_ctl, 3'd0, c4_fdc_nmi, cfdc_present, x_fd_intrq, x_fd_drq, c4_fdc_halt, c4_dbg_a} :
				mz ? zx_dbg :
				{z_do, 3'd0, ~z_m1_n, ~z_wr_n, ~z_rd_n, ~z_iorq_n, ~z_mreq_n, z_a}),   // the other machines: the shared Z80's bus (the Spectrum: its ULA and attribute writes, see bvf_zx)
	.mach(mach), .al_mode(al_mode), .al_we(al_we), .al_waddr(al_waddr), .al_busy(al_busy), .fb_hold(fb_hold), .keys(keys), .keys2(keys2),
	.ide_pending(ide_pending), .ide_req_word(ide_req_word), .ide_lba_word(ide_lba_word), .ide_ack_word(ide_ack_word),
	.ide_ack_we(ide_ack_we), .ide_we(ide_we), .ide_addr(ide_addr), .ide_dout(ide_hdout),
	.ide_present(ide_present), .cart_present(cart_present),
	.frh_pending(frh_pending), .frh_req_word(frh_req_word), .frh_ack_we(frh_ack_we), .frh_we(frh_we),
	.frh_addr(frh_addr), .frh_dout(frh_hdout),
	.ddr_wr(ddr_wr), .ddr_widx(ddr_widx), .ddr_ridx(ddr_ridx), .ddr_rq(ddr_rq),
	.req_pending(req_pending), .req_is_wr(fdc_wr), .copy_busy(copy_busy),
	.req_word(req_word), .ack_word(ack_word), .drv_word(drv_word), .ack_we(ack_we), .drv_we(drv_we),
	.frame_cnt(frame_cnt), .frame_latest(frame_latest), .fb_addr(fb_addr), .fb_dout(fb_dout),
	.aud_count(aud_count), .aud_head(aud_head), .aud_lost(aud_lost), .aud_pop(aud_pop), .aud_clr_lost(aud_clr_lost),
	.sb_addr(sb_addr), .sb_we(sb_we), .sb_dout(sb_dout),
	.rl_we(rl_we), .rl_waddr(rl_waddr)
);

// level interrupt for the UIO driver: a disk request waits, or (see FRAME) the host polls it
assign irq = req_pending | ide_pending | (frh_pending & m300);

endmodule
