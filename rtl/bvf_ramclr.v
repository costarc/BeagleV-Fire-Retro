//
// BeagleV-Fire: the "power on" of the machines' 64 KB RAM. A pulse on `start` writes zero to all 65536 bytes, one per clock
// (1.6 ms at 42 MHz); `active` is high meanwhile and the machine is held in reset. RESET on the real machines keeps the RAM (a
// game survives it, the CoCo's ROM even looks for the warm start flag); only switching off clears it.
//
module bvf_ramclr (
	input         clk,
	input         start,
	output reg    active,
	output reg [15:0] addr
);
initial begin active = 1'b0; addr = 16'd0; end
always @(posedge clk) begin
	if (start) begin
		active <= 1'b1;
		addr   <= 16'd0;
	end else if (active) begin
		addr <= addr + 16'd1;
		if (addr == 16'hFFFF) active <= 1'b0;
	end
end
endmodule
