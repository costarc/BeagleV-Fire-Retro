//
// BeagleV-Fire multicore: the CoCo / CP-400 floppy controller card ($FF40-$FF4F) around the WD1793 of the CP-300 (second bus of ht1080z).
//   $FF40 (and its mirrors up to $FF47)  control register, write; read back:
//         b7 halt enable, b6 drive 3 / side select, b5 density (also enables NMI), b4 write precompensation, b3 motor, b2:0 drive 2:0
//   $FF48-$FF4B (mirrored to $FF4F)       WD1793: command / status, track, sector, data
//   HALT = halt enable and not DRQ: the 6809 stops at the end of the instruction until the next byte is ready (the DOS' transfer loops);
//   INTRQ clears the halt enable (as the card's schematic); NMI = INTRQ and density. Logic of the card as in the MiSTer CoCo2 core
//   (rtl/fdc.sv, Stan Hodge), written again for this bus. The WD1793 runs on a 1 MHz clock enable (its original clock): its timers
//   count these ticks; the CPU's accesses are stretched to three ticks and held while the controller samples them.
// Drives: bit 0..2 of the register select drive 0..2, bit 6 alone selects drive 3; with a drive 0..2 selected bit 6 is the side.
//
module bvf_cocofdc (
	input         clk,                   // 42 MHz
	input         reset,                 // the machine is held, or the controller card is not there
	input         present,               // the card is there (an image is mounted); without it the bus answers $FF and nothing halts
	input         cs,                    // the CPU address is $FF4x
	input         rw,                    // 1 = read
	input   [3:0] a,
	input   [7:0] d,
	input         cyc_end,               // one clk at the end of the CPU's cycle (E falling)
	output  [7:0] q,
	output        halt,
	output        nmi,
	// the WD1793
	output        xf_rst,
	output        xf_ce,
	output        xf_sel,
	output        xf_rd,
	output        xf_wr,
	output  [1:0] xf_addr,
	output  [7:0] xf_din,
	input   [7:0] xf_dout,
	input         xf_drq,
	input         xf_intrq,
	output  [1:0] xf_drive,
	output        xf_side,
	output        motor,
	output  [7:0] dbg_ctl
);

// 1 MHz
reg   [5:0] div = 6'd0;
reg         ce = 1'b0;
always @(posedge clk) begin
	ce <= 1'b0;
	if (div == 6'd41) begin div <= 6'd0; ce <= 1'b1; end else div <= div + 6'd1;
end
assign xf_ce  = ce;
assign xf_rst = reset | ~present;

// the control register
reg   [7:0] ctl = 8'd0;
wire        wr_ctl = cyc_end & cs & ~rw & ~a[3] & present;
always @(posedge clk) begin
	if (reset || !present) ctl <= 8'd0;
	else begin
		if (wr_ctl) ctl <= d;
		if (xf_intrq) ctl[7] <= 1'b0;                  // INTRQ keeps the halt enable cleared
	end
end
assign motor    = ctl[3];
assign dbg_ctl  = ctl;
assign xf_drive = ctl[0] ? 2'd0 : ctl[1] ? 2'd1 : ctl[2] ? 2'd2 : 2'd3;
assign xf_side  = ctl[6] & (ctl[0] | ctl[1] | ctl[2]);
assign halt     = present & ctl[7] & ~xf_drq;
assign nmi      = present & ctl[5] & xf_intrq;

// the WD1793's strobes: a write is taken at the end of the CPU cycle with the data and address held; a read starts with the
// cycle (its address held) and lasts three ticks, so that the controller's clock enable sees it
wire        rdc = cs & rw & a[3] & present;
reg         rdc_d = 1'b0;
reg   [2:0] rd_hold = 3'd0, wr_hold = 3'd0;
reg   [1:0] addr_l = 2'd0;
reg   [7:0] din_l = 8'd0;
always @(posedge clk) begin
	rdc_d <= rdc;
	if (rdc && !rdc_d) begin rd_hold <= 3'd4; addr_l <= a[1:0]; end
	else if (cyc_end && cs && !rw && a[3] && present) begin wr_hold <= 3'd4; addr_l <= a[1:0]; din_l <= d; end
	else begin
		if (ce && rd_hold != 3'd0) rd_hold <= rd_hold - 3'd1;
		if (ce && wr_hold != 3'd0) wr_hold <= wr_hold - 3'd1;
	end
end
assign xf_rd   = (rd_hold != 3'd0);
assign xf_wr   = (wr_hold != 3'd0);
assign xf_sel  = xf_rd | xf_wr;
assign xf_addr = addr_l;
assign xf_din  = din_l;

assign q = !present ? 8'hFF : a[3] ? xf_dout : ctl;

endmodule
