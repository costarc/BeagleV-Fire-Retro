//
// BeagleV-Fire multicore: one pool of block RAMs (LSRAM, 2K x 10) shared by the machines (only one runs at a time).
//
//   the 64 KB RAM (32 blocks, 8 bits used of 10): every machine's RAM, one read and one write address (the owner muxes them);
//                              the Spectrum's ROM is its lower 16 KB
//   the frame buffer (3 sets of 4 blocks = 3 x 2K x 32 bit), the CP-400's cartridge ROM (1 set of 4 blocks = 2K x 32 bit)
//   the CP-400's BASIC and extended BASIC ROMs (2 sets of 4 blocks = 2 x 2K x 32 bit, one read address for both)
//   mx = 1 (the MSX1): the 8 ROM blocks are the MSX1's 16 KB VRAM instead, block k = bytes 2K k .. 2K k + 2047
//
module bvf_blk (
	input         clk,
	input         we,
	input  [10:0] wa,
	input   [9:0] wd,
	input  [10:0] ra,
	output reg [9:0] rq
);
reg [9:0] m [0:2047];
always @(posedge clk) begin
	if (we) m[wa] <= wd;
	rq <= m[ra];
end
endmodule

module bvf_pool (
	input         clk,
	input         mx,
	// the 64 KB RAM: one clock of read latency
	input  [15:0] ram_ra,
	input  [15:0] ram_wa,
	input         ram_we,
	input   [7:0] ram_wd,
	output  [7:0] ram_rq,
	// frame buffer 3 x 2K x 32 (address 0..6143)
	input         fb_we,
	input  [12:0] fb_wa,
	input  [31:0] fb_wd,
	input  [12:0] fb_ra,
	output [31:0] fb_rq,
	// the CP-400's cartridge ROM 2K x 32
	input         cart_we,
	input  [10:0] cart_wa,
	input  [31:0] cart_wd,
	input  [10:0] cart_ra,
	output [31:0] cart_rq,
	// the CP-400's ROMs 2 x 2K x 32: rom_wa[11] = 1 BASIC, 0 extended BASIC; rom_rq = {BASIC, extended BASIC}
	input         rom_we,
	input  [11:0] rom_wa,
	input  [31:0] rom_wd,
	input  [10:0] rom_ra,
	output [63:0] rom_rq,
	// the MSX1's VRAM 16K x 8 (mx = 1)
	input         v_we,
	input  [13:0] v_wa,
	input   [7:0] v_wd,
	input  [13:0] v_ra,
	output  [7:0] v_rq
);

wire  [9:0] rq_ram [0:31];
wire  [9:0] rq_fb  [0:11];      // set s, block k: 4 s + k   (sets 0..2)
wire  [9:0] rq_ct  [0:3];
wire  [9:0] rq_rm  [0:7];       // ROM set s (0 extended, 1 BASIC), block k: 4 s + k

reg   [4:0] ram_sel;
reg   [1:0] fb_sel;
reg   [2:0] v_sel;
always @(posedge clk) begin
	ram_sel <= ram_ra[15:11];
	fb_sel  <= (fb_ra >= 13'd4096) ? 2'd2 : (fb_ra >= 13'd2048) ? 2'd1 : 2'd0;
	v_sel   <= v_ra[13:11];
end
assign ram_rq  = rq_ram[ram_sel][7:0];
assign fb_rq   = {rq_fb[{fb_sel, 2'd3}][1:0], rq_fb[{fb_sel, 2'd2}], rq_fb[{fb_sel, 2'd1}], rq_fb[{fb_sel, 2'd0}]};
assign cart_rq = {rq_ct[3][1:0], rq_ct[2], rq_ct[1], rq_ct[0]};
assign rom_rq  = {rq_rm[7][1:0], rq_rm[6], rq_rm[5], rq_rm[4], rq_rm[3][1:0], rq_rm[2], rq_rm[1], rq_rm[0]};
assign v_rq    = rq_rm[v_sel][7:0];

genvar b, k;
generate
	for (b = 0; b < 32; b = b + 1) begin : rb
		bvf_blk blk (.clk(clk), .we(ram_we & (ram_wa[15:11] == b)), .wa(ram_wa[10:0]), .wd({2'b00, ram_wd}),
			.ra(ram_ra[10:0]), .rq(rq_ram[b]));
	end
	for (b = 0; b < 3; b = b + 1) begin : fs
		for (k = 0; k < 4; k = k + 1) begin : fk
			wire we = fb_we & ((b == 0) ? (fb_wa < 13'd2048) : (b == 1) ? (fb_wa >= 13'd2048 && fb_wa < 13'd4096) : (fb_wa >= 13'd4096));
			bvf_blk blk (.clk(clk), .we(we), .wa(fb_wa[10:0]), .wd(fb_wd[10*k +: ((k == 3) ? 2 : 10)]),
				.ra(fb_ra[10:0]), .rq(rq_fb[4*b + k]));
		end
	end
	for (k = 0; k < 4; k = k + 1) begin : cs
		bvf_blk blk (.clk(clk), .we(cart_we), .wa(cart_wa), .wd(cart_wd[10*k +: ((k == 3) ? 2 : 10)]),
			.ra(cart_ra), .rq(rq_ct[k]));
	end
	for (b = 0; b < 2; b = b + 1) begin : rs
		for (k = 0; k < 4; k = k + 1) begin : rk
			wire we_c = rom_we & (rom_wa[11] == b);
			wire we_v = v_we & (v_wa[13:11] == 4 * b + k);
			bvf_blk blk (.clk(clk), .we(mx ? we_v : we_c), .wa(mx ? v_wa[10:0] : rom_wa[10:0]),
				.wd(mx ? {2'b00, v_wd} : rom_wd[10*k +: ((k == 3) ? 2 : 10)]),
				.ra(mx ? v_ra[10:0] : rom_ra), .rq(rq_rm[4*b + k]));
		end
	end
endgenerate

endmodule
