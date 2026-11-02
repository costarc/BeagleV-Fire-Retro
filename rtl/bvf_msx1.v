//
// BeagleV-Fire multicore: the MSX1. The Z80 is the shared one (bvf_core_bus), the TMS9918A is vdp18 (Arnim Laeuger, msx1/vdp18),
// the PSG is the OCM's (msx1/ocm, licence: msx1/README.md). Everything runs on the 42 MHz clock with enables: ena21 = 45/88 of it
// (21.477 MHz), the Z80 and the PSG at ena21 / 6 (3.58 MHz), the VDP at ena21 / 2 (10.74 MHz).
//
// Slots (no expanded slot): 0 = the MSX BIOS + BASIC (32 KB, pages 0-1) and a 16 KB ROM in page 2 ($63C000, C-BIOS: its logo), 1 = a cartridge ROM up to 32 KB at $4000-$BFFF (cart_en),
// 2 = empty, 3 = 64 KB RAM. The RAM is the pool's 64 KB (no wait), the VRAM the pool's CP-400 ROM blocks (16 KB). The ROMs are in
// DDR (bvf_msxmem: $C800_0000 + $620000 the BIOS, + $640000 the cartridge), loaded by the host while the machine is held, behind an
// 8 KB read cache (the pool's CP-400 cartridge blocks): 1024 lines of 8 bytes, direct mapped; a hit answers without a wait state,
// a miss holds the Z80 (WAIT) until one 64 bit word of DDR is in. The tags are cleared after every reset (the host loads the ROMs
// while the machine is held).
// Picture: the VDP's colour index (0..15) with its 256 x 192 window (240 in text mode) for bvf_fb (one line per picture line).
//
module bvf_msx1 (
	input         clk,
	input         reset,                 // the machine is held while set
	input  [87:0] keys,                  // MSX keyboard matrix, 8 * row + column, 1 = pressed (rows 0..10)
	input         cart_en,               // a cartridge is loaded
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
	// the ROM cache's data in the pool (the CP-400's cartridge blocks: 2K x 32, one clock of read latency)
	output        rc_we,
	output [10:0] rc_wa,
	output [31:0] rc_wd,
	output [10:0] rc_ra,
	input  [31:0] rc_rq,
	// picture, sound
	output        pix_ena,
	output        pix_hb,
	output        pix_vb,
	output  [3:0] pix_idx,
	output  [8:0] audio,
	// the cassette (bvf_tape)
	input         tape_in,
	output  [1:0] tape_out,
	output        tape_motor,
	// the disk interface (slot 2, page 1: a 16 KB ROM and the WD1793 at $3F80.. of the page, the "National" layout of the Gradiente
	// Expert DD Plus): the WD1793 of ht1080z answers on its second bus; the control register is here
	input         disk_en,
	output        fd_rst,
	output        fd_sel,
	output        fd_rd,
	output        fd_wr,
	output  [1:0] fd_addr,
	output  [7:0] fd_din,
	input   [7:0] fd_dout,
	input         fd_drq,
	input         fd_intrq,
	output  [1:0] fd_drive,
	output        fd_side,
	output        fd_motor,

	// DDR
	input         own,                   // this machine owns the AXI master (CTRL.run with the MSX1 selected)
	input         aclk,
	input         aresetn,
	output  [3:0] m_awid,
	output [37:0] m_awaddr,
	output  [7:0] m_awlen,
	output  [2:0] m_awsize,
	output  [1:0] m_awburst,
	output        m_awlock,
	output  [3:0] m_awcache,
	output  [2:0] m_awprot,
	output  [3:0] m_awqos,
	output        m_awvalid,
	input         m_awready,
	output [63:0] m_wdata,
	output  [7:0] m_wstrb,
	output        m_wlast,
	output        m_wvalid,
	input         m_wready,
	input   [3:0] m_bid,
	input   [1:0] m_bresp,
	input         m_bvalid,
	output        m_bready,
	output  [3:0] m_arid,
	output [37:0] m_araddr,
	output  [7:0] m_arlen,
	output  [2:0] m_arsize,
	output  [1:0] m_arburst,
	output        m_arlock,
	output  [3:0] m_arcache,
	output  [2:0] m_arprot,
	output  [3:0] m_arqos,
	output        m_arvalid,
	input         m_arready,
	input   [3:0] m_rid,
	input  [63:0] m_rdata,
	input   [1:0] m_rresp,
	input         m_rlast,
	input         m_rvalid,
	output        m_rready
);

// ---------------------------------------------------------------- clock enables
reg   [7:0] acc = 8'd0;
reg         ena = 1'b0, cen = 1'b0, vena = 1'b0;
reg   [2:0] div6 = 3'd0;
always @(posedge clk) begin
	if (acc + 8'd45 >= 8'd88) begin acc <= acc + 8'd45 - 8'd88; ena <= 1'b1; end
	else begin acc <= acc + 8'd45; ena <= 1'b0; end
	cen <= 1'b0;
	if (ena) begin
		vena <= ~vena;
		if (div6 == 3'd5) begin div6 <= 3'd0; cen <= 1'b1; end else div6 <= div6 + 3'd1;
	end
end
wire        vdp_en = ena & vena;         // 10.74 MHz
wire        psg_en = ena & (div6 == 3'd5);   // 3.58 MHz, on an ena21 tick (the PSG counts when both are set)

reg   [1:0] rst_s = 2'b11;
always @(posedge clk) rst_s <= {rst_s[0], reset};
wire        rst = rst_s[1];
assign z_reset_n = ~rst;
assign z_cen = cen;

// ---------------------------------------------------------------- slots
reg   [7:0] ppi_a = 8'h00, ppi_c = 8'h00;
wire  [1:0] page = z_a[15:14];
wire  [1:0] pri  = ppi_a[2 * page +: 2];
wire        is_mem = ~z_mreq_n & z_rfsh_n;
wire        is_io  = ~z_iorq_n & z_m1_n;
wire        sel_bios = (pri == 2'd0) & ~page[1];
wire        sel_s0p2 = (pri == 2'd0) & (page == 2'd2);                  // slot 0 page 2: a ROM of 16 KB (C-BIOS: its logo)
wire        sel_cart = (pri == 2'd1) & cart_en & (page == 2'd1 || page == 2'd2);
wire        sel_ram  = (pri == 2'd3);
wire        sel_disk = (pri == 2'd2) & disk_en & (page == 2'd1);          // slot 2 page 1: the disk interface
wire        fdc_area = (z_a[13:6] == 8'b11111110);                       // ($4000 + a) & $3FC7 = $3F80..$3F87: bits 5:3 are not decoded
wire        sel_disk2 = (pri == 2'd2) & disk_en & (page == 2'd2);         // the card's registers answer in page 2 too ($BFB8..: the ROM's sector transfer loops run from RAM with the card in page 2); its ROM does not
wire        sel_fdc  = (sel_disk | sel_disk2) & fdc_area;
wire        sel_rom  = sel_bios | sel_s0p2 | sel_cart | (sel_disk & ~fdc_area);
wire [24:0] flat = sel_bios ? (25'h620000 + {10'd0, z_a[14:0]}) : sel_s0p2 ? (25'h63C000 + {11'd0, z_a[13:0]}) :
                   sel_disk ? (25'h648000 + {11'd0, z_a[13:0]}) : (25'h640000 + {10'd0, z_a[14:0] ^ 15'h4000});

// a write is done when WR_n ends: the address and the data are taken while it is low (the T80 puts them out after WR_n falls)
wire        wr_act = (is_mem | is_io) & ~z_wr_n;
reg         wr_act_d = 1'b0, cap_ram = 1'b0, cap_io = 1'b0, cap_fdc = 1'b0;
reg  [15:0] cap_a = 16'd0;
reg   [7:0] cap_d = 8'd0;
always @(posedge clk) begin
	wr_act_d <= wr_act;
	if (wr_act) begin cap_a <= z_a; cap_d <= z_do; cap_ram <= is_mem & sel_ram; cap_io <= is_io; cap_fdc <= is_mem & sel_fdc; end
end
wire        wr_end = wr_act_d & ~wr_act;

assign ram_ra = z_a;
assign ram_wa = cap_a;
assign ram_wd = cap_d;
assign ram_we = wr_end & cap_ram;

// the disk interface's control register ($3F84 of the page; b1:0 select the drive one-hot: 1 = A, 2 = B, as the ROM writes it) and the held strobes for the WD1793 (it samples on the CPU clock enable)
reg   [4:0] fwr_hold = 5'd0;
reg   [1:0] fd_drive_r = 2'd0;
reg         fd_side_r = 1'b0, fd_motor_r = 1'b0;
always @(posedge clk) begin
	if (rst) begin fwr_hold <= 5'd0; fd_drive_r <= 2'd0; fd_side_r <= 1'b0; fd_motor_r <= 1'b0; end
	else if (wr_end && cap_fdc) begin
		if (!cap_a[2]) fwr_hold <= 5'd24;
		else if (cap_a[2:0] == 3'd4) begin fd_drive_r <= {1'b0, cap_d[1]}; fd_side_r <= cap_d[2]; fd_motor_r <= cap_d[3]; end
	end else if (fwr_hold != 5'd0) fwr_hold <= fwr_hold - 5'd1;
end
wire        fdc_rd = sel_fdc & ~z_rd_n & ~z_a[2];
assign fd_rst   = rst;
assign fd_wr    = (fwr_hold != 5'd0);
assign fd_rd    = fdc_rd;
assign fd_sel   = fd_wr | fdc_rd;
assign fd_addr  = fd_wr ? cap_a[1:0] : z_a[1:0];
assign fd_din   = cap_d;
assign fd_drive = fd_drive_r;
assign fd_side  = fd_side_r;
assign fd_motor = fd_motor_r;
wire  [7:0] fdc_dbi = !z_a[2] ? fd_dout : (z_a[1:0] == 2'd0) ? {fd_intrq, ~fd_drq, 6'h3F} : 8'hFF;      // $3F84: b7 INTRQ, b6 /DRQ (low = a byte is ready: the ROM transfers while b6 = 0)

// PPI ($A8-$AB): A = slots, B = keyboard columns, C = keyboard row (3:0), click (7)
always @(posedge clk) begin
	if (rst) begin ppi_a <= 8'h00; ppi_c <= 8'h00; end
	else if (wr_end && cap_io && cap_a[7:2] == 6'b101010) begin
		if (cap_a[1:0] == 2'd0) ppi_a <= cap_d;
		else if (cap_a[1:0] == 2'd2) ppi_c <= cap_d;
		else if (cap_a[1:0] == 2'd3 && !cap_d[7]) ppi_c[cap_d[3:1]] <= cap_d[0];
	end
end
reg   [7:0] krow;
always @(*) begin
	krow = 8'h00;
	if (ppi_c[3:0] < 4'd11) krow = keys[8 * ppi_c[3:0] +: 8];
end
wire  [7:0] kb_col = ~krow;

// ---------------------------------------------------------------- the PSG ($A0-$A2): one ena21 tick per access
reg         rd_act_d = 1'b0, req = 1'b0, p_wrt = 1'b0;
reg  [15:0] p_adr = 16'd0;
reg   [7:0] p_dbo = 8'd0;
wire        rd_act = is_io & ~z_rd_n;
always @(posedge clk) begin
	rd_act_d <= rd_act;
	if (rd_act && !rd_act_d) begin req <= 1'b1; p_adr <= z_a; p_wrt <= 1'b0; end
	else if (wr_end && cap_io) begin req <= 1'b1; p_adr <= cap_a; p_dbo <= cap_d; p_wrt <= 1'b1; end
	else if (ena && req) req <= 1'b0;
end
wire        psg_req = req & (p_adr[7:2] == 6'b101000);
wire  [7:0] psg_dbi, psg_wave;
msx1_psg u_psg (.clk(clk), .ena21(ena), .reset(rst), .clkena(psg_en), .req(psg_req), .wrt(p_wrt), .adr(p_adr), .dbi(psg_dbi),
	.dbo(p_dbo), .wave(psg_wave), .cmtin(tape_in));
assign tape_out   = {1'b0, ppi_c[5]};         // PPI port C b5: cassette out, b4: motor (0 = on)
assign tape_motor = ~ppi_c[4];
assign audio = {1'b0, psg_wave} + {3'b000, ppi_c[7], 5'b00000};

// ---------------------------------------------------------------- the VDP ($98-$99)
wire        vdp_sel = is_io & (z_a[7:1] == 7'b1001100);
wire  [7:0] vdp_dbi;
wire        vdp_int_n, vdp_wait, vram_we;
wire [13:0] vram_a;
wire  [8:0] npix, nline;
wire  [3:0] col;
vdp18_core vdp (.clock_i(clk), .clk_en_10m7_i(vdp_en), .por_i(rst), .reset_i(rst),
	.csr_n_i(~(vdp_sel & ~z_rd_n)), .csw_n_i(~(vdp_sel & ~z_wr_n)), .mode_i({1'b0, z_a[0]}), .int_n_o(vdp_int_n),
	.cd_i(z_do), .cd_o(vdp_dbi), .wait_o(vdp_wait),
	.vram_ce_o(), .vram_oe_o(), .vram_we_o(vram_we), .vram_a_o(vram_a), .vram_d_o(v_wd), .vram_d_i(v_rq),
	.vga_en_i(1'b0), .scanline_en_i(1'b0), .cnt_hor_o(), .cnt_ver_o(), .rgb_r_o(col), .rgb_g_o(), .rgb_b_o(),
	.hsync_n_o(), .vsync_n_o(), .ntsc_pal_i(1'b0), .vertfreq_csw_o(), .vertfreq_d_o(),
	.pix_en_o(pix_ena), .num_pix_o(npix), .num_line_o(nline));
assign v_we = vram_we;
assign v_wa = vram_a;
assign v_ra = vram_a;
assign z_int_n = vdp_int_n;
// the window: pixels 0..255 (the counter stops at 239 in text mode), lines 0..191 (the counters are signed)
assign pix_hb  = npix[8] | (npix[7:0] > 8'd255);
assign pix_vb  = nline[8] | (nline[7:0] > 8'd191);
// bvf_fb takes the blanking as it was at the pixel enable and the colour one clock after it: the VDP's colour changes at the enable, so
// without this delay the first pixel of every line is lost (sim/tb_vdp18win.v)
reg   [3:0] col_q = 4'd0;
always @(posedge clk) col_q <= col;
assign pix_idx = col_q;

// ---------------------------------------------------------------- the ROMs in DDR, behind the cache
// offset in the ROM window ($620000..$647FFF): line = off[12:3], tag = off[17:13]; data row 2 line + off[2] holds bytes 4 off[2] .. + 3
wire        rom_rd = is_mem & sel_rom & ~z_rd_n;
wire [24:0] off_w  = flat - 25'h620000;
wire [17:0] off    = off_w[17:0];
localparam C_IDLE = 3'd0, C_LOOK = 3'd1, C_CMP = 3'd2, C_MISS = 3'd3, C_FILL = 3'd4;
reg   [2:0] cs = C_IDLE;
reg         rom_rd_d = 1'b0, rdy = 1'b0, mstart = 1'b0, clr = 1'b1;
reg   [9:0] clr_i = 10'd0;
reg  [17:0] p_off = 18'd0;
reg  [24:0] p_flat = 25'd0;
reg   [7:0] rom_q = 8'hFF;
reg   [5:0] tags [0:1023];               // {valid, tag}
reg   [5:0] t_q = 6'd0;
wire        cpu_ready;
wire [63:0] q64;
wire        t_we = clr | (cs == C_FILL);
wire  [9:0] t_wa = clr ? clr_i : p_off[12:3];
always @(posedge clk) begin
	if (t_we) tags[t_wa] <= clr ? 6'd0 : {1'b1, p_off[17:13]};
	t_q <= tags[p_off[12:3]];
end
always @(posedge clk) begin
	rom_rd_d <= rom_rd;
	mstart <= 1'b0;
	if (!rom_rd) rdy <= 1'b0;
	if (rst) begin
		cs <= C_IDLE; clr <= 1'b1; clr_i <= 10'd0;
	end else begin
		if (clr) begin clr_i <= clr_i + 10'd1; if (clr_i == 10'd1023) clr <= 1'b0; end
		case (cs)
		C_IDLE: if (rom_rd && !rdy && !clr) begin p_off <= off; p_flat <= flat; cs <= C_LOOK; end
		C_LOOK: cs <= C_CMP;                                   // the tag and the data row are read
		C_CMP:  if (t_q == {1'b1, p_off[17:13]}) begin
		            rom_q <= rc_rq[8 * p_off[1:0] +: 8]; rdy <= 1'b1; cs <= C_IDLE;
		        end else begin mstart <= 1'b1; cs <= C_MISS; end
		C_MISS: if (cpu_ready && !mstart) begin rom_q <= q64[8 * p_off[2:0] +: 8]; cs <= C_FILL; end
		C_FILL: begin rdy <= 1'b1; cs <= C_IDLE; end            // second row and the tag written
		default: cs <= C_IDLE;
		endcase
	end
end
assign rc_ra = {p_off[12:3], p_off[2]};
assign rc_we = ((cs == C_MISS) && cpu_ready && !mstart) || (cs == C_FILL);
assign rc_wa = {p_off[12:3], (cs == C_FILL)};
assign rc_wd = (cs == C_FILL) ? q64[63:32] : q64[31:0];
assign z_wait_n = ~(rom_rd & ~rdy) & ~vdp_wait;

bvf_msxmem mm (
	.clk(clk), .reset(~own),
	.cpu_start(mstart), .cpu_we(1'b0), .cpu_adr(p_flat), .cpu_wd(8'd0), .cpu_ready(cpu_ready), .cpu_rd(), .cpu_rq64(q64),
	.cap_start(1'b0), .cap_off(22'd0), .cap_data(64'd0), .cap_busy(),
	.aclk(aclk), .aresetn(aresetn),
	.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awlock(m_awlock),
	.m_awcache(m_awcache), .m_awprot(m_awprot), .m_awqos(m_awqos), .m_awvalid(m_awvalid), .m_awready(m_awready),
	.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
	.m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
	.m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arlock(m_arlock),
	.m_arcache(m_arcache), .m_arprot(m_arprot), .m_arqos(m_arqos), .m_arvalid(m_arvalid), .m_arready(m_arready),
	.m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready));

// ---------------------------------------------------------------- read data
reg   [7:0] io_dbi;
always @(*) begin
	io_dbi = 8'hFF;
	case (z_a[7:2])
	6'b100110: io_dbi = vdp_dbi;
	6'b101000: io_dbi = psg_dbi;
	6'b101010: case (z_a[1:0]) 2'd0: io_dbi = ppi_a; 2'd1: io_dbi = kb_col; 2'd2: io_dbi = ppi_c; default: io_dbi = 8'hFF; endcase
	default: io_dbi = 8'hFF;
	endcase
end
assign z_di = is_io ? io_dbi : (is_mem & sel_ram) ? ram_rq : (is_mem & sel_fdc) ? fdc_dbi : (is_mem & sel_rom) ? rom_q : 8'hFF;

endmodule
