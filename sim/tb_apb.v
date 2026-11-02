// APB3 slave test: apb_regbus in front of bvf_regs (register path only), plain (PAGED = 0, 20 address bits, as on
// the BeagleV-Fire) and paged (PAGED = 1, a 4 KB window: page register at 0xFFC holds address bits 19:12).
`timescale 1ns/1ps
module tb_apb;
reg clk = 0, pclk = 0, presetn = 0;
always #12 clk = ~clk;
always #5  pclk = ~pclk;      // 100 MHz

reg [19:0] paddr = 0; reg penable = 0, pwrite = 0; reg [31:0] pwdata = 0;
reg [1:0] psel = 0;           // b0 plain bridge, b1 paged bridge
wire [31:0] prdata0, prdata1; wire pready0, pready1, pslverr0, pslverr1;
wire [31:0] prdata = psel[1] ? prdata1 : prdata0;
wire        pready = psel[1] ? pready1 : pready0;

// ---------------------------------------------------------------- plain
wire [19:0] b_addr; wire b_wr, b_rd; wire [31:0] b_wdata, b_rdata;
apb_regbus #(.ABITS(20), .PAGED(0)) apb (.pclk(pclk), .presetn(presetn), .paddr(paddr), .psel(psel[0]), .penable(penable),
	.pwrite(pwrite), .pwdata(pwdata), .prdata(prdata0), .pready(pready0), .pslverr(pslverr0),
	.clk(clk), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata), .b_rd(b_rd), .b_rdata(b_rdata));

wire [63:0] keys; wire run;
bvf_regs regs (
	.frh_pending(1'b0), .frh_req_word(32'd0), .frh_ack_we(), .frh_we(), .frh_addr(), .frh_dout(32'd0),
	.clk(clk), .reset(1'b0), .addr(b_addr), .wr(b_wr), .wdata(b_wdata), .rd(b_rd), .rdata(b_rdata),
	.run(run), .rst_pulse(), .cold_pulse(), .turbo(), .wp_all(), .mach(), .fb_hold(), .keys(keys),
	.req_pending(1'b0), .req_is_wr(1'b0), .copy_busy(1'b0), .req_word(32'd0), .ack_word(32'd0), .drv_word(32'd0),
	.ack_we(), .drv_we(),
	.frame_cnt(16'd7), .frame_latest(1'b1), .fb_addr(), .fb_dout(32'hCAFE0001),
	.aud_count(9'd0), .aud_head(32'd0), .aud_lost(1'b0), .aud_pop(), .aud_clr_lost(),
	.sb_addr(), .sb_we(), .sb_dout(32'd0), .rl_we(), .rl_waddr());

// ---------------------------------------------------------------- paged: only 12 address bits reach the bridge
wire [19:0] p_addr; wire p_wr, p_rd; wire [31:0] p_wdata, p_rdata;
apb_regbus #(.ABITS(12), .PAGED(1)) apbp (.pclk(pclk), .presetn(presetn), .paddr(paddr[11:0]), .psel(psel[1]), .penable(penable),
	.pwrite(pwrite), .pwdata(pwdata), .prdata(prdata1), .pready(pready1), .pslverr(pslverr1),
	.clk(clk), .b_addr(p_addr), .b_wr(p_wr), .b_wdata(p_wdata), .b_rd(p_rd), .b_rdata(p_rdata));

wire [63:0] keys_p;
bvf_regs regsp (
	.frh_pending(1'b0), .frh_req_word(32'd0), .frh_ack_we(), .frh_we(), .frh_addr(), .frh_dout(32'd0),
	.clk(clk), .reset(1'b0), .addr(p_addr), .wr(p_wr), .wdata(p_wdata), .rd(p_rd), .rdata(p_rdata),
	.run(), .rst_pulse(), .cold_pulse(), .turbo(), .wp_all(), .mach(), .fb_hold(), .keys(keys_p),
	.req_pending(1'b0), .req_is_wr(1'b0), .copy_busy(1'b0), .req_word(32'd0), .ack_word(32'd0), .drv_word(32'd0),
	.ack_we(), .drv_we(),
	.frame_cnt(16'd9), .frame_latest(1'b0), .fb_addr(), .fb_dout(32'hBEEF0002),
	.aud_count(9'd0), .aud_head(32'd0), .aud_lost(1'b0), .aud_pop(), .aud_clr_lost(),
	.sb_addr(), .sb_we(), .sb_dout(32'h7AC70003), .rl_we(), .rl_waddr());

task apb_write(input [1:0] which, input [19:0] a, input [31:0] d);
begin
	@(posedge pclk); paddr <= a; pwdata <= d; pwrite <= 1; psel <= which; penable <= 0;
	@(posedge pclk); penable <= 1;
	@(posedge pclk); while (!pready) @(posedge pclk);
	psel <= 0; penable <= 0; pwrite <= 0;
end
endtask
task apb_read(input [1:0] which, input [19:0] a, output [31:0] d);
begin
	@(posedge pclk); paddr <= a; pwrite <= 0; psel <= which; penable <= 0;
	@(posedge pclk); penable <= 1;
	@(posedge pclk); while (!pready) @(posedge pclk);
	d = prdata;
	psel <= 0; penable <= 0;
end
endtask

integer errors = 0;
task check(input [255:0] what, input [31:0] got, input [31:0] exp);
begin
	if (got !== exp) begin errors = errors + 1; $display("FAIL %0s: got %h expected %h", what, got, exp); end
	else $display("ok   %0s", what);
end
endtask
localparam PLAIN = 2'b01, PAGED = 2'b10;
reg [31:0] v;
initial begin
	repeat (5) @(posedge pclk); presetn = 1; repeat (5) @(posedge pclk);
	apb_read(PLAIN, 20'h0, v);          check("ID", v, 32'h43503003);
	apb_write(PLAIN, 20'h0C, 32'h12345678); apb_write(PLAIN, 20'h10, 32'h9ABCDEF0);
	apb_read(PLAIN, 20'h0C, v);         check("KEYS_LO", v, 32'h12345678);
	apb_read(PLAIN, 20'h10, v);         check("KEYS_HI", v, 32'h9ABCDEF0);
	apb_read(PLAIN, 20'h14, v);         check("FRAME", v, 32'h0001_0007);
	apb_read(PLAIN, 20'h30000, v);      check("frame window", v, 32'hCAFE0001);
	apb_write(PLAIN, 20'h04, 32'h1);    apb_read(PLAIN, 20'h04, v); check("CTRL run", v, 1);

	// paged: page 0 after reset, the registers
	apb_read(PAGED, 20'hFFC, v);        check("paged: page register after reset", v, 0);
	apb_read(PAGED, 20'h000, v);        check("paged: ID", v, 32'h43503003);
	apb_write(PAGED, 20'h00C, 32'h0BADF00D);
	apb_read(PAGED, 20'h00C, v);        check("paged: KEYS_LO", v, 32'h0BADF00D);
	check("paged: keys in register file", keys_p[31:0], 32'h0BADF00D);
	apb_read(PAGED, 20'h014, v);        check("paged: FRAME", v, 32'h0000_0009);
	// page 0x30: the frame window; page 0x20: the sector buffer
	apb_write(PAGED, 20'hFFC, 32'h30);
	apb_read(PAGED, 20'hFFC, v);        check("paged: page register", v, 32'h30);
	apb_read(PAGED, 20'h010, v);        check("paged: frame window", v, 32'hBEEF0002);
	apb_write(PAGED, 20'hFFC, 32'h20);
	apb_read(PAGED, 20'h000, v);        check("paged: sector buffer window", v, 32'h7AC70003);
	// a page with nothing behind it reads zero; back to page 0
	apb_write(PAGED, 20'hFFC, 32'h50);
	apb_read(PAGED, 20'h000, v);        check("paged: unmapped page", v, 0);
	apb_write(PAGED, 20'hFFC, 32'h00);
	apb_read(PAGED, 20'h000, v);        check("paged: back on page 0", v, 32'h43503003);
	// the plain bridge did not see any of it
	check("plain: KEYS_LO untouched", keys[31:0], 32'h12345678);
	if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
	$finish;
end
initial begin #4000000; $display("FAIL: timeout"); $finish; end
endmodule
