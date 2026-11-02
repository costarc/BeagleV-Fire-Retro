//
// BeagleV-Fire: the hard disk of the CP-400 (the "MiniIDE" of the Prologica HDB-DOS cartridge): an ATA
// device in PIO mode at $FF50-$FF5F of the CoCo, with the sector I/O done by the host. It replaces the
// OCIDE core + SD card of the original; there is no IDE bus, only the registers the DOS uses.
//
//   CPU side ($FF50 + a)         a=0 data (16 bit through the latch at a=8: the low byte is read or written at $FF50,
//                                the high byte in the latch: read it at $FF58 after the data read, write it at $FF58
//                                before the data write), 1 error / features, 2 sector count, 3 sector number,
//                                4 cylinder low, 5 cylinder high, 6 device/head (LBA: {7:4}, {3:0} = LBA 27:24),
//                                7 status / command, 8 latch.
//   Commands: $20/$21/$C4 read sectors, $30/$31/$C5 write sectors, $EC identify, $90 diagnostic; recalibrate, seek,
//             init parameters, set features and the rest are accepted and ignored (as the original).
//   Status: $80 busy (host working), $50 ready, $58 data request, $51 error (code in the error register).
//
//   host side                    a request (read / write / identify, LBA; req_word b0 read, b1 write, both = identify) is pending until the host answers with
//                                ack_we: the 512 byte sector buffer is the window (h_addr / h_we / h_dout); for a
//                                read the host fills it BEFORE the ack, for a write it reads it first.
//
// The CPU strobe: `cyc_end` is one clock at the end of a CPU cycle (E falling); the address, direction and data
// of that cycle are valid then. Reads present `dout` combinationally from the state before the cycle's side effect.
//
module bvf_ide (
	input         clk,
	input         reset,
	input         present,             // a disk is there; without one the registers read $FF and ignore writes

	// CPU side
	input         cs,                  // the CPU address is $FF5x
	input         cyc_end,
	input         rw,                  // 1 read
	input   [3:0] a,
	input   [7:0] din,
	output  [7:0] dout,

	// host side
	output        pending,
	output [31:0] req_word,            // b0 read, b1 write, both (3) identify
	output [31:0] lba_word,
	output [31:0] ack_word,            // b8..15 error code of the last request, b0 request pending
	input         ack_we,              // b0 = done, b15:8 = error code (0 = ok)
	input  [31:0] wdata,
	input   [6:0] h_addr,
	input         h_we,
	output reg [31:0] h_dout           // one clock after h_addr
);

localparam S_IDLE = 3'd0, S_RBSY = 3'd1, S_RDRQ = 3'd2, S_WDRQ = 3'd3, S_WBSY = 3'd4;

reg   [2:0] st;
reg   [7:0] err, feat, devh, latch;
reg   [7:0] count;
reg  [27:0] lba;
reg   [8:0] nsec;                       // sectors left of the command (a count of 0 means 256)
reg  [9:0]  ptr;                        // byte pointer in the sector buffer
reg   [2:0] kind;                       // the request: 1 read, 2 write, 3 identify (bit 2 is not used: it did not reach the bus on the board)
reg  [27:0] req_lba;
reg         errf;
reg         pend;

// ---- the sector buffer: four byte lanes, one write port, one read port
reg  [7:0] l0 [0:127];
reg  [7:0] l1 [0:127];
reg  [7:0] l2 [0:127];
reg  [7:0] l3 [0:127];
reg [31:0] rd32;

wire        cpu_rd  = cs && cyc_end && rw && present;
wire        cpu_wr  = cs && cyc_end && !rw && present;
wire        d_rd    = cpu_rd && a == 4'd0 && st == S_RDRQ;
wire        d_wr    = cpu_wr && a == 4'd0 && st == S_WDRQ;
wire  [6:0] ridx    = ptr[8:2];

always @(posedge clk) begin
	// host window writes (the CPU does not write while the host works) and CPU data writes
	if (h_we) begin
		l0[h_addr] <= wdata[7:0];  l1[h_addr] <= wdata[15:8];
		l2[h_addr] <= wdata[23:16]; l3[h_addr] <= wdata[31:24];
	end else if (d_wr) begin
		if (!ptr[1]) begin l0[ptr[8:2]] <= din; l1[ptr[8:2]] <= latch; end
		else         begin l2[ptr[8:2]] <= din; l3[ptr[8:2]] <= latch; end
	end
	rd32   <= {l3[ridx], l2[ridx], l1[ridx], l0[ridx]};          // the CPU's read port
	h_dout <= {l3[h_addr], l2[h_addr], l1[h_addr], l0[h_addr]};   // the host's: valid one clock after h_addr
end

// ---- registers as the CPU reads them
wire        busy = (st == S_RBSY) || (st == S_WBSY);
wire        drq  = (st == S_RDRQ) || (st == S_WDRQ);
wire  [7:0] sts  = {busy, !busy, 1'b0, !busy, drq, 2'b00, errf};
wire  [7:0] dlo  = ptr[1] ? rd32[23:16] : rd32[7:0];
wire  [7:0] dhi  = ptr[1] ? rd32[31:24] : rd32[15:8];

reg   [7:0] q;
always @(*) begin
	case (a)
	4'd0:    q = (st == S_RDRQ) ? dlo : 8'h00;
	4'd1:    q = err;
	4'd2:    q = count;
	4'd3:    q = lba[7:0];
	4'd4:    q = lba[15:8];
	4'd5:    q = lba[23:16];
	4'd6:    q = {devh[7:4], lba[27:24]};
	4'd7:    q = sts;
	4'd8:    q = latch;
	default: q = 8'h00;
	endcase
end
assign dout = present ? q : 8'hFF;

assign pending  = pend;
assign req_word = {29'd0, kind};
assign lba_word = {4'd0, req_lba};
assign ack_word = {16'd0, err, 7'd0, pend};

// ---- the machine
wire [8:0] nsec_cmd = (count == 8'd0) ? 9'd256 : {1'b0, count};

always @(posedge clk) begin
	if (reset) begin
		st <= S_IDLE; err <= 8'd0; feat <= 8'd0; devh <= 8'hA0; latch <= 8'd0; count <= 8'd1;
		lba <= 28'd0; nsec <= 9'd0; ptr <= 10'd0; kind <= 3'd0; req_lba <= 28'd0; errf <= 1'b0; pend <= 1'b0;
	end else begin
		// the host answers
		if (ack_we && wdata[0] && pend) begin
			pend <= 1'b0;
			if (wdata[15:8] != 8'd0) begin
				st <= S_IDLE; errf <= 1'b1; err <= wdata[15:8];
			end else if (st == S_RBSY) begin
				st <= S_RDRQ; ptr <= 10'd0;
			end else if (st == S_WBSY) begin
				nsec  <= nsec - 9'd1;
				lba   <= lba + 28'd1;
				count <= count - 8'd1;
				if (nsec == 9'd1) st <= S_IDLE; else begin st <= S_WDRQ; ptr <= 10'd0; end
			end
		end

		if (cpu_rd && a == 4'd0 && st == S_RDRQ) begin
			latch <= dhi;
			ptr   <= ptr + 10'd2;
			if (ptr == 10'd510) begin                     // the sector is read
				if (kind == 3'b011) st <= S_IDLE;         // identify: one sector, the registers stay
				else begin
					nsec  <= nsec - 9'd1;
					lba   <= lba + 28'd1;
					count <= count - 8'd1;
					if (nsec == 9'd1) st <= S_IDLE;
					else begin st <= S_RBSY; kind <= 3'b001; req_lba <= lba + 28'd1; pend <= 1'b1; end
				end
			end
		end
		if (d_wr) begin
			ptr <= ptr + 10'd2;
			if (ptr == 10'd510) begin                     // the sector is full: the host writes it
				st <= S_WBSY; kind <= 3'b010; req_lba <= lba; pend <= 1'b1;
			end
		end

		if (cpu_wr && !busy) begin
			case (a)
			4'd0: ;
			4'd1: feat  <= din;
			4'd2: count <= din;
			4'd3: lba[7:0]   <= din;
			4'd4: lba[15:8]  <= din;
			4'd5: lba[23:16] <= din;
			4'd6: begin devh <= din; lba[27:24] <= din[3:0]; end
			4'd7: begin                                   // command
				errf <= 1'b0; err <= 8'd0;
				case (din)
				8'h20, 8'h21, 8'hC4: begin
					nsec <= nsec_cmd; st <= S_RBSY; kind <= 3'b001; req_lba <= lba; pend <= 1'b1;
				end
				8'h30, 8'h31, 8'hC5: begin
					nsec <= nsec_cmd; st <= S_WDRQ; ptr <= 10'd0;
				end
				8'hEC: begin
					nsec <= 9'd1; st <= S_RBSY; kind <= 3'b011; req_lba <= lba; pend <= 1'b1;
				end
				8'h90: err <= 8'h01;
				default: ;
				endcase
			end
			default: ;
			endcase
		end
		if (cpu_wr && a == 4'd8) latch <= din;
	end
end

endmodule
