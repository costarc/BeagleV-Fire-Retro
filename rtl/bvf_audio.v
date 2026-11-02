//
// CP-300 FPGA, BeagleV-Fire: audio as timestamped level changes. The core's audio is the speaker bit of
// port FF (three levels); every change is pushed as {level[8:0], time[22:0]}, time in microseconds
// (wraps after 8.4 s). The host pops them and plays them with WebAudio. FIFO of 256 entries; when it
// is full new changes are dropped and `lost` is set until the host clears it.
//
module bvf_audio #(parameter CLK_MHZ = 42) (
	input         clk,
	input         reset,
	input   [8:0] audio,
	input         pop,                 // one clock: drop the head entry
	output [31:0] head,                // {level, time} of the entry at the head
	output  [8:0] count,
	output reg    lost,
	input         clr_lost
);

reg [31:0] mem [0:255];
reg  [7:0] rp = 8'd0, wp = 8'd0;
reg  [8:0] cnt = 9'd0;
reg  [8:0] last = 9'h010;
reg [22:0] us = 23'd0;
reg  [5:0] div = 6'd0;

wire do_pop  = pop && cnt != 9'd0;
wire change  = audio != last;
wire full    = cnt == 9'd256;
wire do_push = change && !full;

always @(posedge clk) begin
	if (div == CLK_MHZ - 1) begin div <= 6'd0; us <= us + 23'd1; end
	else div <= div + 6'd1;

	if (reset) begin
		rp <= 8'd0; wp <= 8'd0; cnt <= 9'd0; lost <= 1'b0; last <= audio;
	end else begin
		if (clr_lost) lost <= 1'b0;
		if (change) begin
			last <= audio;
			if (full) lost <= 1'b1;
		end
		if (do_push) begin
			mem[wp] <= {audio, us};
			wp <= wp + 8'd1;
		end
		if (do_pop) rp <= rp + 8'd1;
		cnt <= cnt + (do_push ? 9'd1 : 9'd0) - (do_pop ? 9'd1 : 9'd0);
	end
end

assign head  = cnt == 9'd0 ? 32'd0 : mem[rp];
assign count = cnt;

endmodule
