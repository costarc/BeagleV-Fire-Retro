`timescale 1ns/1ps
module tb_ramclr;
reg clk = 0; always #11.905 clk = ~clk;
reg start = 0; wire active; wire [15:0] addr;
bvf_ramclr dut (.clk(clk), .start(start), .active(active), .addr(addr));
reg [7:0] mem [0:65535];
integer i, nz, writes = 0, errors = 0, cyc = 0;
always @(posedge clk) if (active) begin mem[addr] <= 8'h00; writes <= writes + 1; end
initial begin
	for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hA5;
	repeat (4) @(posedge clk);
	if (active !== 1'b0) begin errors = errors + 1; $display("FAIL active before start"); end
	@(posedge clk); start <= 1; @(posedge clk); start <= 0; @(posedge clk); #1;
	cyc = 0;
	while (active !== 1'b0) begin @(posedge clk); cyc = cyc + 1; end
	repeat (3) @(posedge clk);
	nz = 0; for (i = 0; i < 65536; i = i + 1) if (mem[i] !== 8'h00) nz = nz + 1;
	if (nz != 0) begin errors = errors + 1; $display("FAIL %0d bytes not cleared", nz); end else $display("ok   all 65536 bytes cleared");
	if (writes != 65536) begin errors = errors + 1; $display("FAIL %0d writes", writes); end else $display("ok   65536 writes, %0d clocks", cyc);
	if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
	$finish;
end
endmodule
