// bvf_frehd: the FreHD command interface (C2-C5, CF). A Z80 model does what FreHD's loader.asm does (open a file,
// read a chunk, close) and a host model answers from a small "file".
`timescale 1ns/1ps
module tb_frehd;
reg clk = 0;
always #11.905 clk = ~clk;

reg         reset = 1;
reg   [7:0] a = 0, din = 0;
reg         io_rd = 0, io_wr = 0;
wire  [7:0] dout;
wire        oe, pending;
wire [31:0] req_word, h_dout;
reg         ack_we = 0;
reg  [31:0] ack_wdata = 0;
reg   [7:0] h_addr = 0;
reg         h_we = 0;
reg  [31:0] h_wdata = 0;

bvf_frehd dut (.clk(clk), .reset(reset), .a(a), .io_rd(io_rd), .io_wr(io_wr), .din(din), .dout(dout), .oe(oe),
	.pending(pending), .req_word(req_word), .ack_we(ack_we), .ack_wdata(ack_wdata),
	.h_addr(h_addr), .h_we(h_we), .h_wdata(h_wdata), .h_dout(h_dout));

integer errors = 0;
task check(input [255:0] what, input [31:0] got, input [31:0] want);
	if (got !== want) begin errors = errors + 1; $display("FAIL %0s: got %h want %h", what, got, want); end
	else $display("ok   %0s", what);
endtask

task z_out(input [7:0] port, input [7:0] v);
	begin
		@(posedge clk); a <= port; din <= v; io_wr <= 1;
		repeat (6) @(posedge clk);
		io_wr <= 0;
		repeat (4) @(posedge clk);
	end
endtask
task z_in(input [7:0] port, output [7:0] v);
	begin
		@(posedge clk); a <= port; io_rd <= 1;
		repeat (5) @(posedge clk);
		v = dout;
		@(posedge clk); io_rd <= 0;
		repeat (4) @(posedge clk);
	end
endtask

// the host: a "file" of 600 bytes (byte i = i * 3), answers OPEN, READ, CLOSE, VERSION
reg [7:0] file [0:599];
integer pos = 0, i;
reg [7:0] cmd; reg step; reg [8:0] sz;
integer w;
task host_serve;
	begin
		while (!pending) @(posedge clk);
		cmd = req_word[7:0]; step = req_word[8]; sz = req_word[24:16];
		repeat (20) @(posedge clk);
		case (cmd)
		8'h04: begin                                       // READ_FILE: sz bytes, DRQ
			for (w = 0; w < sz; w = w + 1) begin @(posedge clk); h_we <= 1; h_addr <= w; h_wdata <= file[(pos + w) % 600]; end
			@(posedge clk); h_we <= 0;
			pos = pos + sz;
			@(posedge clk); ack_we <= 1; ack_wdata <= {7'd0, sz, 8'd0, 8'h58};
		end
		8'h03: begin                                       // OPEN_FILE: step 1 returns the size (4 bytes)
			if (step) begin
				@(posedge clk); h_we <= 1; h_addr <= 0; h_wdata <= 8'h58;
				@(posedge clk); h_addr <= 1; h_wdata <= 8'h02;
				@(posedge clk); h_addr <= 2; h_wdata <= 8'h00;
				@(posedge clk); h_addr <= 3; h_wdata <= 8'h00;
				@(posedge clk); h_we <= 0;
				pos = 0;
				@(posedge clk); ack_we <= 1; ack_wdata <= {7'd0, 9'd4, 8'd0, 8'h58};
			end else begin
				@(posedge clk); ack_we <= 1; ack_wdata <= {7'd0, sz, 8'd0, 8'h58};
			end
		end
		default: begin @(posedge clk); ack_we <= 1; ack_wdata <= {7'd0, 9'd0, 8'h05, 8'h51}; end
		endcase
		@(posedge clk); ack_we <= 0;
	end
endtask

reg [7:0] v;
initial begin
	for (i = 0; i < 600; i = i + 1) file[i] = i * 3;
	repeat (5) @(posedge clk);
	reset = 0;
	repeat (5) @(posedge clk);

	// without a command: nothing answers on CF
	@(posedge clk); a <= 8'hCF; io_rd <= 1; @(posedge clk); @(posedge clk);
	check("CF idle: not ours", oe, 0);
	io_rd <= 0;

	// the boot ROM trick: write 3 to C5, read C4: FEh, then the loader (byte 2 = the value written)
	z_out(8'hC5, 8'h03);
	z_in(8'hC4, v); check("boot ROM byte 0 = FE", v, 8'hFE);
	z_in(8'hC4, v); check("boot ROM byte 1 = FE (cp ..)", v, 8'hFE);
	z_in(8'hC4, v); check("boot ROM byte 2 = the value of C5", v, 8'h03);
	z_in(8'hC4, v); check("boot ROM byte 3 = 18 (jr)", v, 8'h18);
	for (i = 4; i < 255; i = i + 1) z_in(8'hC4, v);
	z_in(8'hC4, v); check("boot ROM byte 255 = FF", v, 8'hFF);
	z_out(8'hC5, 8'h05);
	z_in(8'hC4, v); check("a new write to C5 starts again", v, 8'hFE);

	// OPEN_FILE "FREHD.ROM"
	z_out(8'hC4, 8'h03);
	z_in(8'hCF, v); check("busy after COMMAND2", v & 8'h80, 8'h80);
	z_out(8'hC3, 8'd11);                                    // option + 9 + nul
	@(posedge clk); a <= 8'hCF; io_rd <= 1; @(posedge clk); @(posedge clk);
	check("CF is ours while a command runs", oe, 1);
	io_rd <= 0;
	fork host_serve; join                                   // step 0
	z_in(8'hCF, v); check("step 0 done: status 58", v, 8'h58);
	z_out(8'hC2, 8'h01);
	for (i = 0; i < 9; i = i + 1) z_out(8'hC2, "A" + i);
	z_in(8'hCF, v); check("no step 1 yet", v & 8'h80, 8'h00);
	z_out(8'hC2, 8'h00);
	z_in(8'hCF, v); check("busy after the data phase", v & 8'h80, 8'h80);
	check("req: step 1 of OPEN", req_word & 32'h3FF, 32'h303);
	host_serve;                                             // step 1
	z_in(8'hCF, v); check("open done: 58", v, 8'h58);
	z_in(8'hC3, v); check("SIZE2 = 4", v, 4);
	z_in(8'hC2, v); check("file size byte 0", v, 8'h58);
	z_in(8'hC2, v); check("file size byte 1", v, 8'h02);

	// READ_FILE 256 bytes (SIZE2 = 0), then the status DRQ and 256 data reads
	z_out(8'hC3, 8'd0);
	z_out(8'hC4, 8'h04);
	host_serve;
	z_in(8'hCF, v); check("read: DRQ set", v & 8'h08, 8'h08);
	z_in(8'hC3, v); check("read: size low = 0 (256)", v, 0);
	for (i = 0; i < 256; i = i + 1) begin
		z_in(8'hC2, v);
		if (v !== file[i]) begin errors = errors + 1; $display("FAIL data %0d: %h want %h", i, v, file[i]); end
	end
	// second chunk continues
	z_out(8'hC3, 8'd0); z_out(8'hC4, 8'h04); host_serve;
	z_in(8'hC2, v); check("second chunk byte 0 = file[256]", v, file[256]);

	// an error answer
	z_out(8'hC4, 8'h0F);
	host_serve;
	z_in(8'hCF, v); check("error status 51", v, 8'h51);
	z_in(8'hC5, v); check("ERROR2 = 05", v, 8'h05);

	// a WD1010 command on CF hands the status back to the WD1010
	z_out(8'hCF, 8'h10);
	@(posedge clk); a <= 8'hCF; io_rd <= 1; @(posedge clk); @(posedge clk);
	check("after a WD1010 command CF is not ours", oe, 0);
	io_rd <= 0;

	if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
	$finish;
end
initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
