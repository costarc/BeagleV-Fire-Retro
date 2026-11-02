//
// BeagleV-Fire: the sector service of the floppy (WD1793) and hard disk (WD1010) controllers, answered
// by the host. It replaces the IO controller (helper Z80 + DMK firmware) and the data slot mailbox:
// the daemon reads the DMK / HDV image itself and moves one sector at a time.
//
// The protocol of the core (rtl/fdc/wd1793.vhd, rtl/hdc/wd1010.vhd): a request (svc_rd, svc_wr or svc_ra)
// stays up until ack rises; while ack is up the sector buffer belongs to the servicer; the result bits
// are sampled when ack falls.
//
//   host                                   this block                      core
//   read REQ (request, track, sector)  (before ACK: the request drops a few clocks after ack rises)
//   sector read / read address:
//     write ACK = 1                 ---->  the buffer is ours
//     write the data to the window  ---->  4 byte writes per word  ---->  sector buffer
//     write ACK = 0 | result bits   ---->  ack falls, result sampled
//   sector write:
//     write ACK = 1                 ---->  copies the sector buffer to the shadow RAM (about 520 clocks,
//                                          STATUS.copy_busy while it runs)
//     read the window (shadow RAM)
//     write ACK = 0 | result bits
//
// The window writes need 4 clocks each; the register bus puts more than that between two accesses
// (the request crosses two clock domains), so nothing queues.
//
module bvf_fdc (
	input         clk,
	input         reset,                 // high: the request handshake (with the core's reset)
	input         flag_reset,            // high: the drive flags too (PLL lost); they stay set while the core is
	                                     // held, so the host can set them before it releases the core

	// core: the request
	input         svc_rd, svc_wr, svc_ra,
	input   [7:0] svc_track, svc_trkreg, svc_sector,
	input         svc_dam,               // write: deleted data mark
	input   [1:0] svc_drive,
	input         svc_side,
	input         hd_svc,                // the request is the hard disk's
	// core: the answer
	output reg    ack,
	output        res_found, res_crc, res_dam,
	output  [8:0] buff_addr,
	output  [7:0] buff_dout,
	output        buff_wr,
	input   [7:0] buff_din,              // one clock after buff_addr
	output  [3:0] drv_ready, drv_wp,     // floppy drives 0-3
	output  [3:0] hd_flags,              // {write protect 1:0, ready 1:0} of the two hard disks

	// host (bvf_regs)
	output        pending,               // a request waits for the host: the interrupt
	output [31:0] req_word,              // {sector, trkreg, track, hd, dam, drive, side, ra, wr, rd}
	output [31:0] ack_word,              // read back of ACK
	output [31:0] drv_word,              // read back of DRIVES
	output        copy_busy,
	input         ack_we,
	input         drv_we,
	input  [31:0] wdata,
	input   [6:0] h_addr,                // word of the 512 byte window
	input         h_we,
	output [31:0] h_dout                 // one clock after h_addr
);

wire [2:0] req = {svc_ra, svc_wr, svc_rd};
assign pending  = |req & ~ack;
assign req_word = {svc_sector, svc_trkreg, svc_track, hd_svc, svc_dam, svc_drive, svc_side, req};

// ---------------------------------------------------------------- ACK and DRIVES
reg  [2:0] res = 3'd0;
reg  [3:0] f_ready = 4'd0, f_wp = 4'd0;
reg  [1:0] h_ready = 2'd0, h_wp = 2'd0;
reg        start_copy;
initial ack = 1'b0;

always @(posedge clk) begin
	start_copy <= 1'b0;
	if (flag_reset) begin
		f_ready <= 4'd0; f_wp <= 4'd0; h_ready <= 2'd0; h_wp <= 2'd0;
	end else if (drv_we) begin
		f_ready <= wdata[3:0]; f_wp <= wdata[7:4]; h_ready <= wdata[9:8]; h_wp <= wdata[11:10];
	end
	if (reset) begin
		ack <= 1'b0; res <= 3'd0;
	end else begin
		if (ack_we) begin
			ack <= wdata[0];
			res <= wdata[10:8];
			// a write request: take a copy of the buffer for the host to read
			if (wdata[0] && !ack && svc_wr) start_copy <= 1'b1;
		end
	end
end

assign {res_dam, res_crc, res_found} = res;
assign ack_word  = {21'd0, res, 7'd0, ack};
assign drv_word  = {20'd0, h_wp, h_ready, f_wp, f_ready};
assign drv_ready = f_ready;
assign drv_wp    = f_wp;
assign hd_flags  = {h_wp, h_ready};

// ---------------------------------------------------------------- host writes: one word = four bytes
reg  [1:0] wcnt = 2'd0;
reg        wbusy = 1'b0;
reg  [6:0] waddr = 7'd0;
reg [31:0] wword = 32'd0;
always @(posedge clk) begin
	if (reset) wbusy <= 1'b0;
	else if (h_we) begin
		waddr <= h_addr; wword <= wdata; wcnt <= 2'd0; wbusy <= 1'b1;
	end else if (wbusy) begin
		wcnt <= wcnt + 2'd1;
		if (wcnt == 2'd3) wbusy <= 1'b0;
	end
end

// ---------------------------------------------------------------- copy of the buffer for host reads
reg  [9:0] ccnt = 10'd0;               // 0-511 addresses, 512 = the last byte arrives
reg        cbusy = 1'b0;
reg        cwe = 1'b0;
reg  [8:0] cdst = 9'd0;
always @(posedge clk) begin
	cwe <= 1'b0;
	if (reset) cbusy <= 1'b0;
	else if (start_copy) begin
		ccnt <= 10'd0; cbusy <= 1'b1;
	end else if (cbusy) begin
		cwe  <= 1'b1;                  // buff_din of the previous address
		cdst <= ccnt[8:0];
		ccnt <= ccnt + 10'd1;
		if (ccnt == 10'd511) cbusy <= 1'b0;
	end
end
assign copy_busy = cbusy | cwe;

// the shadow RAM: four byte lanes of 128 bytes, read as words, little endian
reg [7:0] sh0 [0:127];
reg [7:0] sh1 [0:127];
reg [7:0] sh2 [0:127];
reg [7:0] sh3 [0:127];
reg [7:0] q0, q1, q2, q3;
always @(posedge clk) begin
	if (cwe && cdst[1:0] == 2'd0) sh0[cdst[8:2]] <= buff_din;
	if (cwe && cdst[1:0] == 2'd1) sh1[cdst[8:2]] <= buff_din;
	if (cwe && cdst[1:0] == 2'd2) sh2[cdst[8:2]] <= buff_din;
	if (cwe && cdst[1:0] == 2'd3) sh3[cdst[8:2]] <= buff_din;
	q0 <= sh0[h_addr]; q1 <= sh1[h_addr]; q2 <= sh2[h_addr]; q3 <= sh3[h_addr];
end
assign h_dout = {q3, q2, q1, q0};

// ---------------------------------------------------------------- the core's buffer port
assign buff_addr = cbusy ? ccnt[8:0] : {waddr, wcnt};
assign buff_wr   = wbusy & ~cbusy;
assign buff_dout = wword[8*wcnt +: 8];

endmodule
