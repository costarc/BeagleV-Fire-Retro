// bvf_ide behind the register block (bvf_regs): the host reads IDE_REQ / IDE_LBA / IDE_ACK / STATUS over the bus while the
// "CPU" issues commands. The IDE module alone is tested in tb_ide.v; this is the path the daemon uses.
`timescale 1ns/1ps
module tb_idebus;
reg clk = 0;
always #11.905 clk = ~clk;
reg reset = 1;
reg [19:0] addr = 0; reg wr = 0, rd = 0; reg [31:0] wdata = 0; wire [31:0] rdata;

reg cs = 0, cyc_end = 0, rw = 1; reg [3:0] a = 0; reg [7:0] din = 0; wire [7:0] dout;
wire ide_pending, ide_ack_we, ide_we, ide_present, cart_present;
wire [31:0] ide_req_word, ide_lba_word, ide_ack_word, ide_hdout; wire [6:0] ide_addr;

bvf_ide ide (.clk(clk), .reset(reset), .present(ide_present), .cs(cs), .cyc_end(cyc_end), .rw(rw), .a(a), .din(din), .dout(dout),
	.pending(ide_pending), .req_word(ide_req_word), .lba_word(ide_lba_word), .ack_word(ide_ack_word),
	.ack_we(ide_ack_we), .wdata(wdata), .h_addr(ide_addr), .h_we(ide_we), .h_dout(ide_hdout));

bvf_regs regs (
	.frh_pending(1'b0), .frh_req_word(32'd0), .frh_ack_we(), .frh_we(), .frh_addr(), .frh_dout(32'd0),
	.clk(clk), .reset(reset), .addr(addr), .wr(wr), .wdata(wdata), .rd(rd), .rdata(rdata),
	.run(), .rst_pulse(), .cold_pulse(), .turbo(), .wp_all(), .mach(), .fb_hold(),
	.ide_pending(ide_pending), .ide_req_word(ide_req_word), .ide_lba_word(ide_lba_word), .ide_ack_word(ide_ack_word),
	.ide_ack_we(ide_ack_we), .ide_we(ide_we), .ide_addr(ide_addr), .ide_dout(ide_hdout),
	.ide_present(ide_present), .cart_present(cart_present),
	.ddr_wr(), .ddr_widx(), .ddr_ridx(), .ddr_rq(32'd0), .keys(),
	.req_pending(1'b0), .req_is_wr(1'b0), .copy_busy(1'b0), .req_word(32'd0), .ack_word(32'd0), .drv_word(32'd0),
	.ack_we(), .drv_we(), .frame_cnt(16'd0), .frame_latest(1'b1), .fb_addr(), .fb_dout(32'd0),
	.aud_count(9'd0), .aud_head(32'd0), .aud_lost(1'b0), .aud_pop(), .aud_clr_lost(),
	.sb_addr(), .sb_we(), .sb_dout(32'd0), .rl_we(), .rl_waddr());

integer errors = 0;
task check(input [511:0] what, input [31:0] got, input [31:0] want);
	if (got !== want) begin errors = errors + 1; $display("FAIL %0s: got %h want %h", what, got, want); end
	else $display("ok   %0s", what);
endtask
task bus_w(input [19:0] ad, input [31:0] v);
	begin @(posedge clk); addr <= ad; wdata <= v; wr <= 1; @(posedge clk); wr <= 0; end
endtask
task bus_r(input [19:0] ad, output [31:0] v);
	begin @(posedge clk); addr <= ad; rd <= 1; @(posedge clk); rd <= 0; repeat (3) @(posedge clk); v = rdata; end
endtask
task cpu_write(input [3:0] ra, input [7:0] v);
	begin
		@(posedge clk); cs <= 1; rw <= 0; a <= ra; din <= v; repeat (4) @(posedge clk);
		cyc_end <= 1; @(posedge clk); cyc_end <= 0; cs <= 0; repeat (3) @(posedge clk);
	end
endtask

reg [31:0] v;
initial begin
	repeat (4) @(posedge clk); reset = 0; repeat (4) @(posedge clk);
	bus_w(20'h5C, 32'd3);                          // IDE_CFG: disk and cartridge present
	bus_r(20'h5C, v); check("IDE_CFG reads back", v, 3);
	cpu_write(4'd7, 8'hEC);                        // identify
	repeat (4) @(posedge clk);
	bus_r(20'h08, v); check("STATUS b4 = IDE pending", v & 32'h10, 32'h10);
	bus_r(20'h50, v); check("IDE_REQ over the bus = identify (3)", v, 3);
	bus_r(20'h54, v); check("IDE_LBA over the bus", v, 0);
	bus_r(20'h58, v); check("IDE_ACK over the bus: pending", v, 1);
	bus_w(20'h58, 32'h1);                          // done
	repeat (4) @(posedge clk);
	bus_r(20'h08, v); check("STATUS b4 clear after the ack", v & 32'h10, 0);
	cpu_write(4'd2, 8'd1); cpu_write(4'd3, 8'd5); cpu_write(4'd7, 8'h20);
	repeat (4) @(posedge clk);
	bus_r(20'h50, v); check("IDE_REQ = read (1)", v, 1);
	bus_r(20'h54, v); check("IDE_LBA = 5", v, 5);
	if (errors == 0) $display("PASS"); else $display("FAIL %0d", errors);
	$finish;
end
endmodule
