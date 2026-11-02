// bvf_ide: the CP-400's hard disk. A CPU model (cycles with cyc_end) and a host model (answers the requests
// from a 4 sector "image"), checking identify, read, multi-sector read, write, errors and the empty bus.
`timescale 1ns/1ps
module tb_ide;
reg clk = 0;
always #11.905 clk = ~clk;

reg         reset = 1, present = 1;
reg         cs = 0, cyc_end = 0, rw = 1;
reg   [3:0] a = 0;
reg   [7:0] din = 0;
wire  [7:0] dout;
wire        pending;
wire [31:0] req_word, lba_word, ack_word;
reg         ack_we = 0;
reg  [31:0] wdata = 0;
reg         h_we = 0;
reg   [6:0] h_addr = 0;
wire [31:0] h_dout;

bvf_ide dut (.clk(clk), .reset(reset), .present(present), .cs(cs), .cyc_end(cyc_end), .rw(rw), .a(a), .din(din), .dout(dout),
	.pending(pending), .req_word(req_word), .lba_word(lba_word), .ack_word(ack_word), .ack_we(ack_we), .wdata(wdata),
	.h_addr(h_addr), .h_we(h_we), .h_dout(h_dout));

integer errors = 0;
task check(input [511:0] what, input [31:0] got, input [31:0] want);
	if (got !== want) begin errors = errors + 1; $display("FAIL %0s: got %h want %h", what, got, want); end
	else $display("ok   %0s", what);
endtask

// the "image": 4 sectors, byte i of sector s = s*37 + i
reg [7:0] img [0:2047];
integer i;
initial for (i = 0; i < 2048; i = i + 1) img[i] = (i / 512) * 37 + i;

// CPU cycles: set up, hold a few clocks, then the end-of-cycle strobe (reads sample dout before it)
task cpu_read(input [3:0] ra, output [7:0] v);
	begin
		@(posedge clk); cs <= 1; rw <= 1; a <= ra;
		repeat (4) @(posedge clk);
		v = dout;
		cyc_end <= 1; @(posedge clk); cyc_end <= 0; cs <= 0;
		repeat (3) @(posedge clk);
	end
endtask
task cpu_write(input [3:0] ra, input [7:0] v);
	begin
		@(posedge clk); cs <= 1; rw <= 0; a <= ra; din <= v;
		repeat (4) @(posedge clk);
		cyc_end <= 1; @(posedge clk); cyc_end <= 0; cs <= 0;
		repeat (3) @(posedge clk);
	end
endtask

// host: answer one request (waits for it)
reg [31:0] last_req, last_lba;
integer w;
task host_serve(input [7:0] err);
	begin
		while (!pending) @(posedge clk);
		last_req = req_word; last_lba = lba_word;
		if (req_word[1:0] == 2'b01) begin                    // read: fill the window, then ack
			for (w = 0; w < 128; w = w + 1) begin
				@(posedge clk); h_we <= 1; h_addr <= w;
				wdata <= {img[(last_lba % 4) * 512 + 4*w + 3], img[(last_lba % 4) * 512 + 4*w + 2],
				          img[(last_lba % 4) * 512 + 4*w + 1], img[(last_lba % 4) * 512 + 4*w]};
			end
			@(posedge clk); h_we <= 0;
		end else if (req_word[1:0] == 2'b11) begin           // identify: word k = k
			for (w = 0; w < 128; w = w + 1) begin
				@(posedge clk); h_we <= 1; h_addr <= w; wdata <= {8'd0, 8'd0, 8'd0, w[7:0]} | 32'h5A000000;
			end
			@(posedge clk); h_we <= 0;
		end else begin                                      // write: read the window into img
			for (w = 0; w < 128; w = w + 1) begin
				@(posedge clk); h_addr <= w;
				@(posedge clk); @(posedge clk); #1;
				{img[(last_lba % 4) * 512 + 4*w + 3], img[(last_lba % 4) * 512 + 4*w + 2],
				 img[(last_lba % 4) * 512 + 4*w + 1], img[(last_lba % 4) * 512 + 4*w]} = h_dout;
			end
					end
		@(posedge clk); ack_we <= 1; wdata <= {16'd0, err, 7'd0, 1'b1};
		@(posedge clk); ack_we <= 0;
	end
endtask

reg [7:0] v, hi;
reg [15:0] word;
integer s, e;
initial begin
	repeat (5) @(posedge clk);
	reset = 0;
	repeat (5) @(posedge clk);

	cpu_read(4'd7, v); check("status idle = $50", v, 8'h50);

	// identify
	cpu_write(4'd7, 8'hEC);
	cpu_read(4'd7, v); check("identify: busy", v & 8'h80, 8'h80);
	host_serve(0);
	repeat (6) @(posedge clk);
	check("identify requested (kind 3)", last_req, 32'h3);
	cpu_read(4'd7, v); check("identify: DRQ, status $58", v, 8'h58);
	e = 0;
	for (i = 0; i < 256; i = i + 1) begin
		cpu_read(4'd0, v); cpu_read(4'd8, hi);
		word = {hi, v};
		// 32 bit word k of the window = {5A, 00, 00, k}: ATA word 2k = {00, k}, word 2k+1 = {5A, 00}
		if (i % 2 == 0 && word !== {8'd0, i[8:1]}) e = e + 1;
		if (i % 2 == 1 && word !== 16'h5A00) e = e + 1;
	end
	check("identify: 256 words", e, 0);
	cpu_read(4'd7, v); check("identify done: $50", v, 8'h50);

	// read sector 2 (LBA 2), count 1
	cpu_write(4'd2, 8'd1); cpu_write(4'd3, 8'd2); cpu_write(4'd4, 8'd0); cpu_write(4'd5, 8'd0); cpu_write(4'd6, 8'hE0);
	cpu_write(4'd7, 8'h20);
	host_serve(0);
	repeat (6) @(posedge clk);
	check("read: LBA", last_lba, 2);
	e = 0;
	for (i = 0; i < 256; i = i + 1) begin
		cpu_read(4'd0, v); cpu_read(4'd8, hi);
		if (v !== img[2 * 512 + 2 * i] || hi !== img[2 * 512 + 2 * i + 1]) e = e + 1;
	end
	check("read: 512 bytes", e, 0);
	cpu_read(4'd7, v); check("read done: $50", v, 8'h50);
	cpu_read(4'd3, v); check("LBA register advanced", v, 3);

	// read two sectors (LBA 0 and 1): the second request follows by itself
	cpu_write(4'd2, 8'd2); cpu_write(4'd3, 8'd0);
	cpu_write(4'd7, 8'h20);
	host_serve(0);
	repeat (6) @(posedge clk);
	e = 0;
	for (i = 0; i < 256; i = i + 1) begin
		cpu_read(4'd0, v); cpu_read(4'd8, hi);
		if (v !== img[2 * i] || hi !== img[2 * i + 1]) e = e + 1;
	end
	cpu_read(4'd7, v); check("2 sectors: busy again for the second", v & 8'h80, 8'h80);
	host_serve(0);
	repeat (6) @(posedge clk);
	check("2 sectors: second LBA", last_lba, 1);
	for (i = 0; i < 256; i = i + 1) begin
		cpu_read(4'd0, v); cpu_read(4'd8, hi);
		if (v !== img[512 + 2 * i] || hi !== img[512 + 2 * i + 1]) e = e + 1;
	end
	check("2 sectors: 1024 bytes", e, 0);
	cpu_read(4'd7, v); check("2 sectors done: $50", v, 8'h50);

	// write LBA 3
	cpu_write(4'd2, 8'd1); cpu_write(4'd3, 8'd3);
	cpu_write(4'd7, 8'h30);
	cpu_read(4'd7, v); check("write: DRQ at once, $58", v, 8'h58);
	for (i = 0; i < 256; i = i + 1) begin
		cpu_write(4'd8, 8'hC0 + i[7:0] + 1);          // high byte into the latch first
		cpu_write(4'd0, 8'hC0 + i[7:0]);              // then the low byte
	end
	cpu_read(4'd7, v); check("write: busy while the host stores", v & 8'h80, 8'h80);
	host_serve(0);
	repeat (6) @(posedge clk);
	check("write requested", last_req, 32'h2);
	check("write: LBA", last_lba, 3);
	e = 0;
	for (i = 0; i < 256; i = i + 1)
		if (img[3 * 512 + 2 * i] !== (8'hC0 + i[7:0]) || img[3 * 512 + 2 * i + 1] !== (8'hC0 + i[7:0] + 8'd1)) e = e + 1;
	check("write: 512 bytes in the image", e, 0);
	cpu_read(4'd7, v); check("write done: $50", v, 8'h50);

	// an error from the host
	cpu_write(4'd2, 8'd1); cpu_write(4'd3, 8'd9);
	cpu_write(4'd7, 8'h20);
	host_serve(8'h10);
	repeat (6) @(posedge clk);
	cpu_read(4'd7, v); check("error: status $51", v, 8'h51);
	cpu_read(4'd1, v); check("error: register $10", v, 8'h10);

	// recalibrate is accepted, clears the error
	cpu_write(4'd7, 8'h10);
	cpu_read(4'd7, v); check("recalibrate: $50", v, 8'h50);

	// no disk: the bus is empty
	present = 0;
	cpu_read(4'd7, v); check("no disk: $FF", v, 8'hFF);
	cpu_write(4'd7, 8'h20);
	repeat (6) @(posedge clk);
	check("no disk: no request", pending, 0);

	if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
	$finish;
end
endmodule
