// bvf_tape: play with the motor gate, hold entries, underrun, flush; record with timestamps and the FIFO pop.
`timescale 1ns/1ps
module tb_tape;
reg clk = 0;
always #11.905 clk = ~clk;                 // 42 MHz
reg reset = 1;
reg ctl_we = 0, play_we = 0, rec_pop = 0, motor = 0;
reg [31:0] wd = 0;
reg [1:0] tape_out = 0;
wire [31:0] ctl_rdata, recn, rec_head;
wire tape_in;
bvf_tape dut (.clk(clk), .reset(reset), .ctl_we(ctl_we), .ctl_wdata(wd), .ctl_rdata(ctl_rdata), .play_we(play_we), .play_wdata(wd),
	.recn_rdata(recn), .rec_pop(rec_pop), .rec_head(rec_head), .motor(motor), .tape_out(tape_out), .tape_in(tape_in));

integer errs = 0;
task ctl(input [31:0] v); begin @(negedge clk); wd = v; ctl_we = 1; @(negedge clk); ctl_we = 0; end endtask
task push(input hold, input [19:0] us); begin @(negedge clk); wd = {hold, 11'd0, us}; play_we = 1; @(negedge clk); play_we = 0; end endtask
task check(input ok, input [255:0] what); begin if (!ok) begin errs = errs + 1; $display("FAIL: %0s at %0t", what, $time); end end endtask

time t0, t1;
integer i;
initial begin
	repeat (10) @(negedge clk); reset = 0;
	// 1. play 3 entries (100, 200, 300 us) with the motor off: nothing happens
	ctl(32'h80);                          // clear sticky
	ctl(32'h40);                          // level 0
	push(0, 100); push(0, 200); push(0, 300);
	ctl(32'h01);                          // play
	#(500_000);
	check(tape_in == 0, "level stays low while the motor is off");
	check(dut.rp == 0, "nothing consumed while the motor is off");
	// 2. the motor on: the level toggles at 100 us, 300 us, 600 us after the start
	motor = 1;
	@(posedge tape_in); t0 = $time;
	@(negedge tape_in); t1 = $time;
	$display("first high %0t ns after the motor, high lasted %0d us", t0, (t1 - t0) / 1000);
	check((t1 - t0) / 1000 >= 199 && (t1 - t0) / 1000 <= 202, "second entry: 200 us");
	@(posedge tape_in); t0 = $time;
	check((t0 - t1) / 1000 >= 299 && (t0 - t1) / 1000 <= 302, "third entry: 300 us");
	#(50_000);
	check(ctl_rdata[10] == 1, "underrun after the FIFO ran dry"); // the level is held, the underrun flag is sticky
	ctl(32'h81);                          // play, clear sticky
	check(ctl_rdata[10] == 0, "underrun cleared");
	// 3. a hold entry keeps the level over its end
	ctl(32'h03);                          // flush the FIFO, play stays on
	ctl(32'h41);                          // level 0 again (bit 6 strobe, bit 5 = 0), play
	t1 = $time;
	push(1, 100); push(0, 100); push(0, 100);
	@(posedge tape_in); t0 = $time;      // the first toggle comes after 200 us (the hold entry does not toggle)
	check(t0 - t1 > 190_000 && t0 - t1 < 215_000, "hold: no toggle after the first entry");
	// 4. the motor off pauses the tape in the middle
	#(1_000);
	motor = 0;
	#(300_000);
	// 5. record: three changes
	ctl(32'h0C);                          // flush the record FIFO, record on
	ctl(32'h04);                          // record on (no flush)
	@(negedge clk); tape_out = 2'b01; #(100_000);
	@(negedge clk); tape_out = 2'b10; #(200_000);
	@(negedge clk); tape_out = 2'b00; #(50_000);
	check(recn[9:0] == 3, "three changes recorded");
	$display("records: %h %h %h", rec_head, 0, 0);
	check(rec_head[31:30] == 2'b01 && rec_head[28:0] <= 2, "first record: level 01 at once");
	@(negedge clk); rec_pop = 1; @(negedge clk); rec_pop = 0; repeat (4) @(negedge clk);
	check(rec_head[31:30] == 2'b10 && rec_head[28:0] >= 99 && rec_head[28:0] <= 101, "second record: level 10 after 100 us");
	@(negedge clk); rec_pop = 1; @(negedge clk); rec_pop = 0; repeat (4) @(negedge clk);
	check(rec_head[31:30] == 2'b00 && rec_head[28:0] >= 199 && rec_head[28:0] <= 201, "third record: level 00 after 200 us");
	if (errs == 0) $display("tape bench: PASS"); else $display("tape bench: %0d errors", errs);
	$finish;
end
endmodule
