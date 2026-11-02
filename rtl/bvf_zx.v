//
// BeagleV-Fire multicore: a ZX Spectrum 48K. The Z80 is the shared one (bvf_core_bus) at 3.5 MHz (42 MHz / 12); the ULA is written
// here (no contention, no floating bus).
//
// Memory: the pool's 64 KB RAM, the ROM in its lower 16 KB (the Z80 cannot write there). The host loads the ROM while the machine is
// held, through the ROM load port (rl_*: 32 bit words, the first byte in bits 31:24, word address = byte address / 4).
// The pool RAM has one read port: in every T-state (12 clocks) the Z80's address is on it except at clocks 2 and 3 of the second
// T-state of a character cell, where the ULA reads the bitmap and the attribute byte of the next cell. The Z80 takes its data at
// clock 11 (the CEN clock), so it never sees the ULA's.
//
// Video: 448 pixels (7 MHz) x 312 lines per frame, 50.08 Hz; the picture is pixels 0..255 of lines 64..255, INT for the first
// 32 T-states of line 0. Picture out: the colour index {bright, green, red, blue} with its 256 x 192 window for bvf_fb; the border
// colour (port $FE bits 2:0) is an output of its own.
//
module bvf_zx (
	input         clk,
	input         reset,                 // the machine is held while set
	input  [63:0] keys,                  // 8 half rows x 5 keys: keys[8 r + c] = row r (address line A(8 + r)), bit c; 1 = pressed
	// the ROM loader
	input         rl_we,
	input  [12:0] rl_waddr,
	input  [31:0] rl_wdata,
	// the shared Z80
	output        z_reset_n,
	output        z_cen,
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
	// picture, sound
	input         tape_in,                // EAR (port $FE bit 6)
	output  [1:0] tape_out,               // MIC (port $FE bit 3)
	output reg    pix_ena,
	output        pix_hb,
	output        pix_vb,
	output  [3:0] pix_idx,
	output  [2:0] border,
	output  [8:0] audio,
	output [31:0] dbg                     // {last data written to $5800..$5AFF, number of those writes (saturates), the ULA's last attribute, its last bitmap} (/api/debug)
);

reg   [1:0] rst_s = 2'b11;
always @(posedge clk) rst_s <= {rst_s[0], reset};
wire        rst = rst_s[1];
assign z_reset_n = ~rst;

// ---------------------------------------------------------------- timing: T-state = 12 clocks, pixel = 6
reg   [3:0] tc = 4'd0;
reg   [8:0] hc = 9'd0;                   // pixel 0..447
reg   [8:0] vc = 9'd0;                   // line 0..311
reg   [4:0] fcnt = 5'd0;                 // frames (FLASH = bit 4)
wire        adv = (tc == 4'd5) || (tc == 4'd11);
always @(posedge clk) begin
	tc <= (tc == 4'd11) ? 4'd0 : tc + 4'd1;
	if (adv) begin
		if (hc == 9'd447) begin
			hc <= 9'd0;
			if (vc == 9'd311) begin vc <= 9'd0; fcnt <= fcnt + 5'd1; end
			else vc <= vc + 9'd1;
		end else hc <= hc + 9'd1;
	end
end
assign z_cen   = (tc == 4'd11);
assign z_int_n = ~((vc == 9'd0) && (hc < 9'd64));

// ---------------------------------------------------------------- the ULA's fetches
// in the T-state with hc[2:1] = 1 of cell hc[8:3], the cell after it: bitmap at tc 2, attribute at tc 3 (data one clock later)
wire  [5:0] fcell = hc[8:3] + 6'd1;                     // 1..56; 56 = cell 0 of the next line
wire  [8:0] fline = (fcell == 6'd56) ? ((vc == 9'd311) ? 9'd0 : vc + 9'd1) : vc;
wire  [7:0] fy    = fline[7:0] - 8'd64;                 // picture line when fline is 64..255
wire  [4:0] fx    = (fcell == 6'd56) ? 5'd0 : fcell[4:0];
wire [15:0] a_bm  = {3'b010, fy[7:6], fy[2:0], fy[5:3], fx};
wire [15:0] a_at  = {6'b010110, fy[7:3], fx};
wire        f_slot = (hc[2:1] == 2'd1) & ~hc[0];          // the first pixel of that T-state: tc 0..5 of it
wire        f_bm  = f_slot & (tc == 4'd2);
wire        f_at  = f_slot & (tc == 4'd3);
reg         f_bm_d = 1'b0, f_at_d = 1'b0;
reg   [7:0] bm_n = 8'd0, at_n = 8'd0;                    // the next cell
always @(posedge clk) begin
	f_bm_d <= f_bm; f_at_d <= f_at;
	if (f_bm_d) bm_n <= ram_rq;
	if (f_at_d) at_n <= ram_rq;
end

// ---------------------------------------------------------------- pixels
reg   [7:0] sh = 8'd0, at = 8'd0;
always @(posedge clk) begin
	pix_ena <= adv;
	if (adv) begin
		if (hc[2:0] == 3'd7) begin sh <= bm_n; at <= at_n; end
		else sh <= {sh[6:0], 1'b0};
	end
end
wire        ink_on = sh[7] ^ (at[7] & fcnt[4]);
assign pix_idx = {at[6], ink_on ? at[2:0] : at[5:3]};
assign pix_hb  = (hc >= 9'd256);
assign pix_vb  = (vc < 9'd64) || (vc >= 9'd256);

// ---------------------------------------------------------------- the Z80's bus
wire        is_mem = ~z_mreq_n & z_rfsh_n;
wire        is_io  = ~z_iorq_n & z_m1_n;
wire        wr_act = (is_mem | is_io) & ~z_wr_n;
reg         wr_act_d = 1'b0, cap_mem = 1'b0, cap_io = 1'b0;
reg  [15:0] cap_a = 16'd0;
reg   [7:0] cap_d = 8'd0;
always @(posedge clk) begin
	wr_act_d <= wr_act;
	if (wr_act) begin cap_a <= z_a; cap_d <= z_do; cap_mem <= is_mem; cap_io <= is_io; end
end
wire        wr_end = wr_act_d & ~wr_act;

// port $FE (A0 = 0): border, MIC, EAR
reg   [4:0] fe = 5'd0;
always @(posedge clk) if (rst) fe <= 5'd0; else if (wr_end && cap_io && !cap_a[0]) fe <= cap_d[4:0];
assign border = fe[2:0];
reg   [7:0] wat_d = 8'd0, wat_n = 8'd0;
always @(posedge clk) if (wr_end && cap_mem && cap_a[15:8] >= 8'h58 && cap_a[15:8] <= 8'h5A) begin
	wat_d <= cap_d;
	if (wat_n != 8'hFF) wat_n <= wat_n + 8'd1;
end
assign dbg    = {wat_d, wat_n, at_n, bm_n};
assign tape_out = {1'b0, fe[3]};
assign audio  = (fe[4] ? 9'd192 : 9'd0) + (fe[3] ? 9'd24 : 9'd0);

// keyboard: the half rows whose address line is low
reg   [4:0] kb;
integer r;
always @(*) begin
	kb = 5'b11111;
	for (r = 0; r < 8; r = r + 1) if (!z_a[8 + r]) kb = kb & ~keys[8 * r +: 5];
end
assign z_di = (is_io && !z_a[0]) ? {1'b1, tape_in, 1'b1, kb} : is_io ? 8'hFF : ram_rq;

// ---------------------------------------------------------------- the RAM ports, the ROM loader
reg   [1:0] lb = 2'd0;                   // byte of the loaded word
reg         lbusy = 1'b0;
reg  [12:0] lw_a = 13'd0;
reg  [31:0] lw_d = 32'd0;
always @(posedge clk) begin
	if (rl_we && rst) begin lw_a <= rl_waddr; lw_d <= rl_wdata; lbusy <= 1'b1; lb <= 2'd0; end
	else if (lbusy) begin
		lb <= lb + 2'd1;
		lw_d <= {lw_d[23:0], 8'h00};
		if (lb == 2'd3) lbusy <= 1'b0;
	end
end
assign ram_ra = f_bm ? a_bm : f_at ? a_at : z_a;
assign ram_wa = lbusy ? {1'b0, lw_a, lb} : cap_a;
assign ram_wd = lbusy ? lw_d[31:24] : cap_d;
assign ram_we = lbusy | (wr_end & cap_mem & (cap_a[15:14] != 2'b00) & ~rst);

endmodule
