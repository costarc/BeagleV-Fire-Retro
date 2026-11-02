//
// CP-300 FPGA, BeagleV-Fire: the FreHD's second command interface (ports C2-C5, CF while a command runs).
//
// The FreHD board is more than a WD1010: its PIC also answers a file / clock / drive command set, which the
// boot disks of the FreHD pack use to load FREHD.ROM from the SD card, to read the directory and to mount hard
// disk images. The WD1010 (rtl/hdc/wd1010.vhd, C8-CF) is left as it is; this block sits on the core's
// expansion bus (exp_*) and takes C2-C5, and CF while a command is running.
//
// The Z80 side is the firmware's (veco/FreHDv1 sw/trs_hard/interrupt.asm, trs_extra.c):
//   C4 w COMMAND2  starts a command: byte count 0, "step 0" runs on the host, status = BUSY until it is done
//   C3 w SIZE2     bytes of the data phase (0 = 256)       C3 r the size the host left
//   C2 rw DATA2    the 256 byte buffer, with a byte counter that counts every access; when a write brings the counter
//                  to SIZE2 the command's "step 1" runs on the host (status BUSY again)
//   C5 r ERROR2    the error code of the host
//   CF r STATUS    while a command has run: the status the host answered (BUSY, READY, SEEKDONE, DRQ, ERR),
//                  until the Z80 writes a WD1010 command to CF
//   CE w           (also seen by the WD1010) selects the drive for READ_HEADER: bits 4:3
//   C5 w / C4 r    the boot ROM trick of the Model III / 4P ROMs and the FreHD boot disks: the Z80 writes a value to C5, then
//                  reads C4: the first byte is FEh, the next 255 are the 256 byte loader of the PIC's EEPROM (loader.asm,
//                  loaded to 5000h; byte 2 is the value written to C5). The loader then reads FREHD.ROM with the commands.
//
// The host (daemon) sees REQ and answers with ACK. Both are registers of bvf_regs (0x98, 0x9C), the buffer is its
// window 0x50000 (word n = byte n of the buffer in bits 7:0).
//
//   REQ  [7:0] command  [8] step (0: after COMMAND2, 1: after the data phase)  [9] pending  [10] drive (SDH bit 3)
//        [15] 1  [25:16] SIZE2 (0..256)  [26] drive bit 4
//   ACK  w: [7:0] status for CF  [15:8] ERROR2  [25:16] SIZE2 after the command; clears pending, byte counter = 0
//
module bvf_frehd (
	input         clk,
	input         reset,
	// the Z80's I/O cycle (exp bus: strobes are high during the whole cycle)
	input   [7:0] a,
	input         io_rd,
	input         io_wr,
	input   [7:0] din,
	output  [7:0] dout,
	output        oe,
	// the host
	output        pending,
	output [31:0] req_word,
	input         ack_we,
	input  [31:0] ack_wdata,
	input   [7:0] h_addr,
	input         h_we,
	input  [31:0] h_wdata,
	output [31:0] h_dout
);

// the loader (sw/trs_hard/loader_eeprom.asm of veco/FreHDv1, built from sw/z80/frehd_rom/loader.asm)
function [7:0] boot_rom(input [7:0] i);
	case (i)
	8'd0: boot_rom = 8'hFE;
	8'd1: boot_rom = 8'hFE;
	8'd2: boot_rom = 8'hFF;
	8'd3: boot_rom = 8'h18;
	8'd4: boot_rom = 8'h02;
	8'd5: boot_rom = 8'h18;
	8'd6: boot_rom = 8'h19;
	8'd7: boot_rom = 8'h3A;
	8'd8: boot_rom = 8'h40;
	8'd9: boot_rom = 8'h38;
	8'd10: boot_rom = 8'hE6;
	8'd11: boot_rom = 8'h80;
	8'd12: boot_rom = 8'hC0;
	8'd13: boot_rom = 8'h11;
	8'd14: boot_rom = 8'h16;
	8'd15: boot_rom = 8'h50;
	8'd16: boot_rom = 8'h06;
	8'd17: boot_rom = 8'h09;
	8'd18: boot_rom = 8'hCD;
	8'd19: boot_rom = 8'h1F;
	8'd20: boot_rom = 8'h50;
	8'd21: boot_rom = 8'hC0;
	8'd22: boot_rom = 8'hE9;
	8'd23: boot_rom = 8'h46;
	8'd24: boot_rom = 8'h52;
	8'd25: boot_rom = 8'h45;
	8'd26: boot_rom = 8'h48;
	8'd27: boot_rom = 8'h44;
	8'd28: boot_rom = 8'h2E;
	8'd29: boot_rom = 8'h52;
	8'd30: boot_rom = 8'h4F;
	8'd31: boot_rom = 8'h4D;
	8'd32: boot_rom = 8'h21;
	8'd33: boot_rom = 8'h00;
	8'd34: boot_rom = 8'h00;
	8'd35: boot_rom = 8'h39;
	8'd36: boot_rom = 8'hE5;
	8'd37: boot_rom = 8'hDD;
	8'd38: boot_rom = 8'hE1;
	8'd39: boot_rom = 8'hEB;
	8'd40: boot_rom = 8'h3E;
	8'd41: boot_rom = 8'h03;
	8'd42: boot_rom = 8'hD3;
	8'd43: boot_rom = 8'hC4;
	8'd44: boot_rom = 8'hCD;
	8'd45: boot_rom = 8'hA4;
	8'd46: boot_rom = 8'h50;
	8'd47: boot_rom = 8'h78;
	8'd48: boot_rom = 8'h3C;
	8'd49: boot_rom = 8'h3C;
	8'd50: boot_rom = 8'hD3;
	8'd51: boot_rom = 8'hC3;
	8'd52: boot_rom = 8'h0E;
	8'd53: boot_rom = 8'hC2;
	8'd54: boot_rom = 8'h3E;
	8'd55: boot_rom = 8'h01;
	8'd56: boot_rom = 8'hED;
	8'd57: boot_rom = 8'h79;
	8'd58: boot_rom = 8'hED;
	8'd59: boot_rom = 8'hB3;
	8'd60: boot_rom = 8'hAF;
	8'd61: boot_rom = 8'hED;
	8'd62: boot_rom = 8'h79;
	8'd63: boot_rom = 8'hCD;
	8'd64: boot_rom = 8'hA4;
	8'd65: boot_rom = 8'h50;
	8'd66: boot_rom = 8'hC0;
	8'd67: boot_rom = 8'h0E;
	8'd68: boot_rom = 8'hFF;
	8'd69: boot_rom = 8'hCD;
	8'd70: boot_rom = 8'h7F;
	8'd71: boot_rom = 8'h50;
	8'd72: boot_rom = 8'h3D;
	8'd73: boot_rom = 8'h20;
	8'd74: boot_rom = 8'h0C;
	8'd75: boot_rom = 8'hCD;
	8'd76: boot_rom = 8'h70;
	8'd77: boot_rom = 8'h50;
	8'd78: boot_rom = 8'hCD;
	8'd79: boot_rom = 8'h7F;
	8'd80: boot_rom = 8'h50;
	8'd81: boot_rom = 8'h77;
	8'd82: boot_rom = 8'h23;
	8'd83: boot_rom = 8'h10;
	8'd84: boot_rom = 8'hF9;
	8'd85: boot_rom = 8'h18;
	8'd86: boot_rom = 8'hEE;
	8'd87: boot_rom = 8'h3D;
	8'd88: boot_rom = 8'h28;
	8'd89: boot_rom = 8'h0B;
	8'd90: boot_rom = 8'hCD;
	8'd91: boot_rom = 8'h7F;
	8'd92: boot_rom = 8'h50;
	8'd93: boot_rom = 8'h47;
	8'd94: boot_rom = 8'hCD;
	8'd95: boot_rom = 8'h7F;
	8'd96: boot_rom = 8'h50;
	8'd97: boot_rom = 8'h10;
	8'd98: boot_rom = 8'hFB;
	8'd99: boot_rom = 8'h18;
	8'd100: boot_rom = 8'hE0;
	8'd101: boot_rom = 8'hCD;
	8'd102: boot_rom = 8'h70;
	8'd103: boot_rom = 8'h50;
	8'd104: boot_rom = 8'h3E;
	8'd105: boot_rom = 8'h06;
	8'd106: boot_rom = 8'hD3;
	8'd107: boot_rom = 8'hC4;
	8'd108: boot_rom = 8'hCD;
	8'd109: boot_rom = 8'hA4;
	8'd110: boot_rom = 8'h50;
	8'd111: boot_rom = 8'hAF;
	8'd112: boot_rom = 8'hC9;
	8'd113: boot_rom = 8'hCD;
	8'd114: boot_rom = 8'h7F;
	8'd115: boot_rom = 8'h50;
	8'd116: boot_rom = 8'h47;
	8'd117: boot_rom = 8'hCD;
	8'd118: boot_rom = 8'h7F;
	8'd119: boot_rom = 8'h50;
	8'd120: boot_rom = 8'h6F;
	8'd121: boot_rom = 8'h05;
	8'd122: boot_rom = 8'hCD;
	8'd123: boot_rom = 8'h7F;
	8'd124: boot_rom = 8'h50;
	8'd125: boot_rom = 8'h67;
	8'd126: boot_rom = 8'h05;
	8'd127: boot_rom = 8'hC9;
	8'd128: boot_rom = 8'h0C;
	8'd129: boot_rom = 8'h20;
	8'd130: boot_rom = 8'h03;
	8'd131: boot_rom = 8'hCD;
	8'd132: boot_rom = 8'h88;
	8'd133: boot_rom = 8'h50;
	8'd134: boot_rom = 8'hDB;
	8'd135: boot_rom = 8'hC2;
	8'd136: boot_rom = 8'hC9;
	8'd137: boot_rom = 8'hAF;
	8'd138: boot_rom = 8'hD3;
	8'd139: boot_rom = 8'hC3;
	8'd140: boot_rom = 8'h3E;
	8'd141: boot_rom = 8'h04;
	8'd142: boot_rom = 8'hD3;
	8'd143: boot_rom = 8'hC4;
	8'd144: boot_rom = 8'hCD;
	8'd145: boot_rom = 8'hA4;
	8'd146: boot_rom = 8'h50;
	8'd147: boot_rom = 8'h20;
	8'd148: boot_rom = 8'h05;
	8'd149: boot_rom = 8'hDB;
	8'd150: boot_rom = 8'hCF;
	8'd151: boot_rom = 8'hE6;
	8'd152: boot_rom = 8'h08;
	8'd153: boot_rom = 8'hC0;
	8'd154: boot_rom = 8'h3E;
	8'd155: boot_rom = 8'h06;
	8'd156: boot_rom = 8'hD3;
	8'd157: boot_rom = 8'hC4;
	8'd158: boot_rom = 8'hCD;
	8'd159: boot_rom = 8'hA4;
	8'd160: boot_rom = 8'h50;
	8'd161: boot_rom = 8'hDD;
	8'd162: boot_rom = 8'hF9;
	8'd163: boot_rom = 8'h3C;
	8'd164: boot_rom = 8'hC9;
	8'd165: boot_rom = 8'hDB;
	8'd166: boot_rom = 8'hCF;
	8'd167: boot_rom = 8'h07;
	8'd168: boot_rom = 8'h38;
	8'd169: boot_rom = 8'hFB;
	8'd170: boot_rom = 8'hDB;
	8'd171: boot_rom = 8'hCF;
	8'd172: boot_rom = 8'hE6;
	8'd173: boot_rom = 8'h01;
	8'd174: boot_rom = 8'hC9;
	default: boot_rom = 8'hFF;
	endcase
endfunction

localparam P_DATA2 = 8'hC2, P_SIZE2 = 8'hC3, P_CMD2 = 8'hC4, P_ERR2 = 8'hC5, P_SDH = 8'hCE, P_STAT = 8'hCF;

reg        rd_q = 1'b0, wr_q = 1'b0;
reg  [7:0] ca = 8'd0, cd = 8'd0;
reg  [7:0] cmd = 8'd0, bd = 8'd0, err2 = 8'd0, stat = 8'd0;
reg  [8:0] size = 9'd256;
reg        step = 1'b0, busy = 1'b0, st_valid = 1'b0;
reg  [1:0] drv = 2'd0;
reg  [7:0] rom_val = 8'd0, rom_idx = 8'd0;      // the boot ROM trick: value written to C5, bytes of C4 read since

wire wr_fall = wr_q & ~io_wr;
wire rd_fall = rd_q & ~io_rd;

// the 256 byte buffer: the Z80 on one port (byte counter), the host on the other
reg  [7:0] ram [0:255];
reg  [7:0] qa = 8'd0, qb = 8'd0;
wire       we_a = wr_fall && ca == P_DATA2;
always @(posedge clk) begin
	if (we_a) ram[bd] <= cd;
	qa <= ram[bd];
end
always @(posedge clk) begin
	if (h_we) ram[h_addr] <= h_wdata[7:0];
	qb <= ram[h_addr];
end
assign h_dout = {24'd0, qb};

wire [7:0] bd_next = bd + 8'd1;

always @(posedge clk) begin
	rd_q <= io_rd;
	wr_q <= io_wr;
	if (io_rd | io_wr) ca <= a;
	if (io_wr)         cd <= din;

	if (reset) begin
		busy <= 1'b0; st_valid <= 1'b0; bd <= 8'd0; step <= 1'b0; size <= 9'd256; err2 <= 8'd0; drv <= 2'd0;
	end else begin
		if (rd_fall && ca == P_DATA2) bd <= bd_next;
		if (rd_fall && ca == P_CMD2)  rom_idx <= rom_idx + 8'd1;

		if (wr_fall) begin
			case (ca)
			P_CMD2: begin
				cmd <= cd; bd <= 8'd0; step <= 1'b0; busy <= 1'b1; st_valid <= 1'b1; stat <= 8'hC0;
			end
			P_SIZE2: size <= (cd == 8'd0) ? 9'd256 : {1'b0, cd};
			P_DATA2: begin
				bd <= bd_next;
				if (bd_next == size[7:0]) begin step <= 1'b1; busy <= 1'b1; st_valid <= 1'b1; stat <= 8'hC0; end
			end
			P_SDH:  drv <= cd[4:3];
			P_STAT: st_valid <= 1'b0;
			P_ERR2: begin rom_val <= cd; rom_idx <= 8'd0; end       // write to C5
			default: ;
			endcase
		end

		if (ack_we) begin
			stat <= ack_wdata[7:0]; err2 <= ack_wdata[15:8];
			size <= ack_wdata[24:16];
			bd <= 8'd0; busy <= 1'b0;
		end
	end
end

assign pending  = busy;
assign req_word = {5'd0, drv[1], 1'b0, size, 1'b1, 4'd0, drv[0], busy, step, cmd};

assign oe   = io_rd && (a == P_DATA2 || a == P_SIZE2 || a == P_ERR2 || a == P_CMD2 || (a == P_STAT && st_valid));
assign dout = a == P_DATA2 ? qa :
              a == P_SIZE2 ? size[7:0] :
              a == P_ERR2  ? err2 :
              a == P_CMD2  ? (rom_idx == 8'd2 ? rom_val : boot_rom(rom_idx)) : stat;

endmodule
