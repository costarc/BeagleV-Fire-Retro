//
// BeagleV-Fire multicore: the cassette recorder shared by all machines.
//
// Play: the host pushes pulse durations into a FIFO (1024 words): [19:0] microseconds, [31] hold. The tape input level starts at the
// level the host set (CTRL b6/b5) and toggles at the end of every entry (not after an entry with the hold bit set: a pause longer
// than 2^20 us is split into entries). Time only runs while PLAY is on and the machine's motor is on (or FORCE is set), as with a
// real recorder whose motor the computer switches: the tape waits where it is. An empty FIFO while running holds the level
// (UNDERRUN is sticky).
// Record: every change of the machine's tape output (2 bits: the CP-300's 3 level output, the others use bit 0) is stored as
// {level[1:0], 0, microseconds since the previous change [28:0]} (FIFO of 512 words, OVERFLOW sticky).
//
//   CTRL  w: b0 play, b1 flush the play FIFO (pulse), b2 record, b3 flush the record FIFO (pulse), b4 frc (ignore the motor),
//            b5 level to set, b6 set the level (pulse), b7 clear UNDERRUN / OVERFLOW
//         r: b0 play, b2 record, b4 frc, b5 level, b8 running (play + motor + data), b9 play FIFO empty, b10 underrun,
//            b11 overflow, b12 motor, [26:16] free words of the play FIFO
//   PLAY  w: push an entry (ignored while the FIFO is full)
//   RECN  r: [9:0] entries in the record FIFO     RECD r: the oldest entry; w: remove it
//
module bvf_tape (
	input         clk,                   // 42 MHz
	input         reset,
	input         ctl_we,
	input  [31:0] ctl_wdata,
	output [31:0] ctl_rdata,
	input         play_we,
	input  [31:0] play_wdata,
	output [31:0] recn_rdata,
	input         rec_pop,
	output [31:0] rec_head,
	input         motor,                 // 1 = the machine runs the tape motor
	input   [1:0] tape_out,
	output        tape_in
);

// 1 us tick
reg   [5:0] div = 6'd0;
reg         tick = 1'b0;
reg  [28:0] us = 29'd0;
always @(posedge clk) begin
	tick <= 1'b0;
	if (div == 6'd41) begin div <= 6'd0; tick <= 1'b1; us <= us + 29'd1; end else div <= div + 6'd1;
end

reg         play = 1'b0, rec = 1'b0, frc = 1'b0, level = 1'b0, underrun = 1'b0, ovf = 1'b0;
reg         flush_p = 1'b0, flush_r = 1'b0;
always @(posedge clk) begin
	flush_p <= 1'b0; flush_r <= 1'b0;
	if (reset) begin play <= 1'b0; rec <= 1'b0; frc <= 1'b0; end
	else if (ctl_we) begin
		play <= ctl_wdata[0]; flush_p <= ctl_wdata[1]; rec <= ctl_wdata[2]; flush_r <= ctl_wdata[3]; frc <= ctl_wdata[4];
	end
end

// ---------------------------------------------------------------- play
reg  [31:0] pm [0:1023];
reg  [10:0] wp = 11'd0, rp = 11'd0;
reg  [31:0] pq = 32'd0;
wire [10:0] cnt = wp - rp;
wire        empty = (cnt == 11'd0);
wire        full  = (cnt == 11'd1024);
wire [10:0] free  = 11'd1024 - cnt;
always @(posedge clk) begin
	if (play_we && !full) pm[wp[9:0]] <= play_wdata;
	pq <= pm[rp[9:0]];
end
reg         active = 1'b0, ld = 1'b0, hold = 1'b0;
reg  [19:0] left = 20'd0;
wire        run = play & (motor | frc);
always @(posedge clk) begin
	if (reset || flush_p) begin wp <= 11'd0; rp <= 11'd0; active <= 1'b0; ld <= 1'b0; end
	else begin
		if (play_we && !full) wp <= wp + 11'd1;
		if (ld) begin                                   // pq is the entry at rp
			ld <= 1'b0; active <= 1'b1; hold <= pq[31]; left <= (pq[19:0] == 20'd0) ? 20'd1 : pq[19:0]; rp <= rp + 11'd1;
		end else if (!active && !empty && run) ld <= 1'b1;
		if (active && run && tick) begin
			if (left == 20'd1) begin active <= 1'b0; if (!hold) level <= ~level; end
			else left <= left - 20'd1;
		end
	end
	if (ctl_we && ctl_wdata[6]) level <= ctl_wdata[5];
	if (run && !active && empty && tick) underrun <= 1'b1;
	if (ctl_we && ctl_wdata[7]) underrun <= 1'b0;
end
assign tape_in = level;

// ---------------------------------------------------------------- record
reg  [31:0] rm [0:511];
reg   [9:0] rwp = 10'd0, rrp = 10'd0;
reg  [31:0] rq = 32'd0;
wire  [9:0] rcnt = rwp - rrp;
reg   [1:0] prev = 2'd0;
reg  [28:0] last = 29'd0;
reg         rec_d = 1'b0;
wire        chg = rec & rec_d & (tape_out != prev);
always @(posedge clk) begin
	rec_d <= rec;
	if (!rec_d) begin prev <= tape_out; last <= us; end
	else if (tape_out != prev) begin prev <= tape_out; last <= us; end
	if (chg) begin
		if (rcnt < 10'd511) begin rm[rwp[8:0]] <= {tape_out, 1'b0, us - last}; rwp <= rwp + 10'd1; end
		else ovf <= 1'b1;
	end
	if (ctl_we && ctl_wdata[7]) ovf <= 1'b0;
	if (reset || flush_r) begin rwp <= 10'd0; rrp <= 10'd0; end
	else if (rec_pop && rcnt != 10'd0) rrp <= rrp + 10'd1;
	rq <= rm[rrp[8:0]];
end
assign rec_head   = rq;
assign recn_rdata = {22'd0, rcnt};
assign ctl_rdata  = {5'd0, free, 3'd0, motor, ovf, underrun, empty, run & (active | !empty), 2'd0, level, frc, 1'b0, rec, 1'b0, play};

endmodule
