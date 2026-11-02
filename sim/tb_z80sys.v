// tb_z80sys.v: bvf_core_bus with the shared Z80, driven through its register bus as the daemon does: select the machine, load its
// ROM, run it, read the frame buffer. An AXI4 slave model holds the DDR (the MSX1's ROMs at $C862_0000 / $C863_C000).
//   MACH 6  the MSX1's disk interface: a test program in the BIOS slot reads sector 3 of track 0 through the WD1793 at $7FB8 of slot 2;
//           the bench answers the sector request as the daemon does (bytes (5 i + 3) & 255) and checks the 512 bytes in RAM
//   MACH 5  the Matra Alice: the host writes the VRAM words and the $BFFF latch of alice_vram.hex (alice/emu: alice MC10.BIN -dump alice_vram.hex)
//   MACH 0  the CP-300 with a test ROM (gen_z80_roms.py): the RAM it fills is checked
//   MACH 2  the MSX1 with C-BIOS          MACH 3  the ZX Spectrum with the 48K ROM          MACH 4  the MC-1000 with its ROM
// At the end the frame buffer (256 x 192 colour indexes) is written to frame.ppm.
`timescale 1ns/1ps
module tb_z80sys;
parameter MACH = 3;
parameter RUN_MS = 100;
parameter TRACE_MS = 0;
parameter VDPDBG = 0;
localparam MM = (MACH == 6) ? 2 : (MACH == 7) ? 1 : MACH;                            // 6 is the MSX1 with the disk test program
localparam [31:0] MSEL = ((MM & 3) << 4) | ((MM >> 2) << 8);   // CTRL b5:4 the low bits of the machine, b9:8 the high bits
reg clk = 0, aclk = 0;
always #11.905 clk = ~clk;
always #4 aclk = ~aclk;
reg aresetn = 0;

reg  [19:0] b_addr = 0; reg b_wr = 0, b_rd = 0; reg [31:0] b_wdata = 0; wire [31:0] b_rdata;
wire [3:0] awid, arid; wire [37:0] awaddr, araddr; wire [7:0] awlen, arlen, wstrb; wire awvalid, wvalid, wlast, bready, arvalid, rready;
wire [63:0] wdata; reg awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0, rlast = 0; reg [63:0] rdata = 0;

bvf_core_bus dut (.clk(clk), .pll_locked(1'b1), .b_addr(b_addr), .b_wr(b_wr), .b_wdata(b_wdata), .b_rd(b_rd), .b_rdata(b_rdata), .irq(),
	.aclk(aclk), .aresetn(aresetn),
	.m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(), .m_awburst(), .m_awlock(), .m_awcache(), .m_awprot(), .m_awqos(),
	.m_awvalid(awvalid), .m_awready(awready), .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
	.m_bid(4'd0), .m_bresp(2'b00), .m_bvalid(bvalid), .m_bready(bready),
	.m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(), .m_arburst(), .m_arlock(), .m_arcache(), .m_arprot(), .m_arqos(),
	.m_arvalid(arvalid), .m_arready(arready), .m_rid(4'd0), .m_rdata(rdata), .m_rresp(2'b00), .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready));

// ---------------------------------------------------------------- AXI slave: 8 MB at $C800_0000, random latency, single beats or bursts
reg [63:0] mem [0:(1<<20)-1];
reg [37:0] aw_l; reg aw_have = 0, w_have = 0; reg [63:0] w_l; reg [7:0] s_l;
integer d;
always @(posedge aclk) begin
	awready <= 0; wready <= 0; bvalid <= bvalid & ~bready;
	if (awvalid && !aw_have && ($random % 3 == 0)) begin awready <= 1; aw_l <= awaddr; aw_have <= 1; end
	if (wvalid && !w_have && ($random % 3 == 0)) begin wready <= 1; w_l <= wdata; s_l <= wstrb; w_have <= 1; end
	if (aw_have && w_have && !bvalid) begin
		for (d = 0; d < 8; d = d + 1) if (s_l[d]) mem[(aw_l - 38'h00C8000000) >> 3][8*d +: 8] = w_l[8*d +: 8];
		aw_have <= 0; w_have <= 0; bvalid <= 1;
	end
end
reg [19:0] r_l; reg r_busy = 0; integer r_wait = 0; reg [7:0] r_n;
always @(posedge aclk) begin
	arready <= 0;
	if (rvalid && rready) begin rvalid <= 0; rlast <= 0; end
	if (arvalid && !r_busy && !arready && ($random % 2 == 0)) begin
		arready <= 1; r_l <= (araddr - 38'h00C8000000) >> 3; r_n <= arlen; r_busy <= 1; r_wait <= 20 + {$random} % 30;
	end
	if (r_busy && !arready && !(rvalid && !rready)) begin
		if (r_wait != 0) r_wait <= r_wait - 1;
		else if (!rvalid || rready) begin
			rdata <= mem[r_l]; rvalid <= 1; rlast <= (r_n == 0);
			r_l <= r_l + 1; r_n <= r_n - 1;
			if (r_n == 0) r_busy <= 0;
		end
	end
end

// ---------------------------------------------------------------- the register bus
task wr32(input [19:0] a, input [31:0] v);
begin
	@(negedge clk); b_addr = a; b_wdata = v; b_wr = 1;
	@(negedge clk); b_wr = 0;
end
endtask
task rd32(input [19:0] a, output [31:0] v);
begin
	@(negedge clk); b_addr = a; b_rd = 1;
	@(negedge clk); b_rd = 0;
	@(negedge clk); @(negedge clk); v = b_rdata;
end
endtask

// ---------------------------------------------------------------- MACH 6: the host's sector service (what cp300d.py does): REQ, ACK up, the 512 bytes into the window, ACK with `found`
reg svc_on = 0;
integer n_req = 0, sv_i;
reg [31:0] sv_w, sv_req;
initial begin
	wait (svc_on);
	while (svc_on) begin
		#(4000);
		rd32(20'h00008, sv_w);
		if (sv_w[2]) begin
			rd32(20'h00040, sv_req);
			if (sv_req[0]) begin
				n_req = n_req + 1;
				$display("%t sector request: track %0d, sector %0d, side %0d", $time, sv_req[15:8], sv_req[31:24], sv_req[3]);
				wr32(20'h00044, 32'h1);
				for (sv_i = 0; sv_i < ((MACH == 7) ? 64 : 128); sv_i = sv_i + 1) begin
					repeat (6) @(negedge clk);                  // the window takes 4 clocks a word; the host's APB writes are slower anyway
					wr32(20'h20000 + 4 * sv_i, {8'(((4 * sv_i + 3) * 5 + 3) & 255), 8'(((4 * sv_i + 2) * 5 + 3) & 255), 8'(((4 * sv_i + 1) * 5 + 3) & 255), 8'(((4 * sv_i) * 5 + 3) & 255)});
				end
				repeat (6) @(negedge clk);
				wr32(20'h00044, 32'h100);
			end
		end
	end
end

// ---------------------------------------------------------------- the run
reg [31:0] avram [0:1536];
reg [7:0] rom0 [0:32767];
reg [7:0] rom1 [0:16383];
reg [31:0] w;
reg [3:0] pix [0:49151];
reg [23:0] pal [0:15];
integer i, f, x, y, err = 0;
initial begin
	// MSX1 (TMS9918, approximate) and Spectrum ({bright, g, r, b}) palettes for the picture
	if (MACH == 2) begin
		pal[0] = 24'h000000; pal[1] = 24'h000000; pal[2] = 24'h21C842; pal[3] = 24'h5EDC78; pal[4] = 24'h5455ED; pal[5] = 24'h7D76FC;
		pal[6] = 24'hD4524D; pal[7] = 24'h42EBF5; pal[8] = 24'hFC5554; pal[9] = 24'hFF7978; pal[10] = 24'hD4C154; pal[11] = 24'hE6CE80;
		pal[12] = 24'h21B03B; pal[13] = 24'hC95BBA; pal[14] = 24'hCCCCCC; pal[15] = 24'hFFFFFF;
	end else if (MACH == 4 || MACH == 5) begin       // the MC6847 (mc1000/mc1000_vdg_pack-p.vhd)
		pal[0] = 24'h000000; pal[1] = 24'h000000; pal[2] = 24'h007C00; pal[3] = 24'h910000; pal[4] = 24'h000000; pal[5] = 24'h000000;
		pal[6] = 24'h000000; pal[7] = 24'h000000; pal[8] = 24'h07FF00; pal[9] = 24'hFFFF00; pal[10] = 24'h3B08FF; pal[11] = 24'hCC003B;
		pal[12] = 24'hFFFFFF; pal[13] = 24'h07E399; pal[14] = 24'hFF1CFF; pal[15] = 24'hFF8100;
	end else
		for (i = 0; i < 16; i = i + 1)
			pal[i] = {(i & 2) ? (i & 8 ? 8'hFF : 8'hD7) : 8'h00, (i & 4) ? (i & 8 ? 8'hFF : 8'hD7) : 8'h00, (i & 1) ? (i & 8 ? 8'hFF : 8'hD7) : 8'h00};
	for (i = 0; i < (1<<20); i = i + 1) mem[i] = 64'hFFFFFFFFFFFFFFFF;
	$readmemh("rom0.hex", rom0);
	$readmemh("rom1.hex", rom1);
	repeat (20) @(negedge clk); aresetn = 1;
	wr32(20'h00004, MSEL);                      // the machine, held
	if (MACH == 5) begin
		// nothing to load: the emulated 6803 is on the host
	end else if (MACH == 7) begin
		for (i = 0; i < 8192; i = i + 4) begin wr32(20'h10000 + 8192 + i, {rom0[i], rom0[i + 1], rom0[i + 2], rom0[i + 3]}); repeat (8) @(negedge clk); end   // Color BASIC: the test program
	end else if (MACH == 2 || MACH == 6) begin
		for (i = 0; i < 32768; i = i + 1) mem[(24'h620000 >> 3) + (i >> 3)][8*(i & 7) +: 8] = rom0[i];
		for (i = 0; i < 16384; i = i + 1) mem[(24'h63C000 >> 3) + (i >> 3)][8*(i & 7) +: 8] = rom1[i];
	end else
		for (i = 0; i < 16384; i = i + 4) begin wr32(20'h10000 + i, {rom0[i], rom0[i + 1], rom0[i + 2], rom0[i + 3]}); repeat (8) @(negedge clk); end   // the Spectrum's loader writes a word as 4 bytes: the host's APB writes are slower than 2 clocks
	if (MACH == 7) begin
		wr32(20'h0005C, 32'h8);                     // IDE_CFG b3: the CP-400's floppy controller is there
		wr32(20'h00048, 32'h1);                     // DRIVES: floppy 0 ready
		svc_on = 1;
	end
	if (MACH == 6) begin
		mem[24'h648000 >> 3][7:0] = 8'h41;          // the first byte of the disk ROM in slot 2
		wr32(20'h0005C, 32'h4);                     // IDE_CFG b2: the disk interface is there
		wr32(20'h00048, 32'h1);                     // DRIVES: floppy 0 ready
		svc_on = 1;
		wr32(20'h000A4, 32'h40);                    // the tape input starts low
		for (i = 0; i < 400; i = i + 1) wr32(20'h000A8, 32'd500);     // 400 pulses of 500 us
		wr32(20'h000A4, 32'h11);                    // play, whatever the motor says
	end
	wr32(20'h00004, (MSEL) | 1 | 32'h80);      // run, with COLD (the RAM is cleared, the ROMs stay) as the daemon powers on
	$display("%t running machine %0d", $time, MACH);
	if (MACH == 5) begin
		$readmemh("alice_vram.hex", avram);
		wr32(20'h000A0, avram[0]);                  // the $BFFF latch
		for (i = 0; i < 1536; i = i + 1) begin
			wr32(20'h60000 + 4 * i, avram[1 + i]);
			repeat (8) @(negedge clk);              // the window takes 4 clocks a word (the host's writes are far slower)
		end
		rd32(20'h000A0, w);
		$display("ALICE mode %h, window busy %0d", w[7:0], w[8]);
	end
	#(RUN_MS * 1000000.0);
	rd32(20'h00014, w);
	$display("frames %0d", w[15:0]);
	vram_x;
	$display("Z80 enables %0d, RAM writes %0d, VRAM writes %0d, undefined VRAM bytes %0d of 16384, Z80 address %h",
		n_cen, n_ramw, n_vw, n_vx, dut.z_a);
	if (TRACE_MS > 0) hist_print;
	if (MACH == 3) begin
		// the Spectrum's display file and attributes in the pool's RAM blocks
		$display("ZX RAM: bitmap %h %h %h %h %h %h %h %h, attributes %h %h %h %h %h %h %h %h", ram_byte(16'h4000), ram_byte(16'h4001), ram_byte(16'h4002), ram_byte(16'h4003),
			ram_byte(16'h4100), ram_byte(16'h4101), ram_byte(16'h4102), ram_byte(16'h4103),
			ram_byte(16'h5800), ram_byte(16'h5801), ram_byte(16'h5802), ram_byte(16'h5803), ram_byte(16'h5900), ram_byte(16'h5901), ram_byte(16'h5902), ram_byte(16'h5903));
	end
	if (MACH == 7) begin
		$display("debug: ctl %h, halt %b, drq %b, intrq %b, present %b, cpu address %h", dut.cfdc.ctl, dut.c4_fdc_halt, dut.x_fd_drq, dut.x_fd_intrq, dut.cfdc_present, dut.cp400.cpu_a);
		err = 0;
		for (i = 0; i < 256; i = i + 1) if (ram_byte(16'h4000 + i) !== 8'((5 * i + 3) & 255)) begin err = err + 1; if (err < 4) $display("byte %0d: %h, expected %h", i, ram_byte(16'h4000 + i), (5 * i + 3) & 255); end
		$display("CP-400 floppy: status %h (00), done marker %h (5a), %0d bad bytes of 256, %0d sector requests", ram_byte(16'h4100), ram_byte(16'h4101), err, n_req);
		$display("SAM page 1: RAM $C200 = %h (55 when P1 was set), RAM $4200 = %h (00)", ram_byte(16'hC200), ram_byte(16'h4200));
		if (ram_byte(16'hC200) != 8'h55 || ram_byte(16'h4200) != 8'h00) err = err + 1000;
		if (err == 0 && ram_byte(16'h4100) == 8'h00 && ram_byte(16'h4101) == 8'h5A && n_req == 1) $display("CP-400 floppy: PASS"); else $display("CP-400 floppy: FAIL");
	end
	if (MACH == 6) begin
		err = 0;
		for (i = 0; i < 512; i = i + 1) if (ram_byte(16'hE000 + i) !== 8'((5 * i + 3) & 255)) begin err = err + 1; if (err < 4) $display("byte %0d: %h, expected %h", i, ram_byte(16'hE000 + i), (5 * i + 3) & 255); end
		$display("MSX tape: %0d changes of the cassette input counted by the Z80 (PSG register 14, bit 7)", ram_byte(16'hF110));
		$display("MSX disk: ROM byte %h (41), status after RESTORE %h, status after READ SECTOR %h (00), done marker %h (5a), %0d bad bytes of 512, %0d sector requests",
			ram_byte(16'hF100), ram_byte(16'hF101), ram_byte(16'hF102), ram_byte(16'hF103), err, n_req);
		if (ram_byte(16'hF110) < 8'd20) err = err + 1000;
		if (err == 0 && ram_byte(16'hF100) == 8'h41 && ram_byte(16'hF102) == 8'h00 && ram_byte(16'hF103) == 8'h5A && n_req == 1) $display("MSX disk: PASS"); else $display("MSX disk: FAIL");
	end
	if (MACH == 0) begin
		// the test program's RAM writes, read from the pool's RAM blocks
		for (i = 0; i < 256; i = i + 1) if (ram_byte(16'h4000 + i) !== i[7:0]) err = err + 1;
		if (ram_byte(16'h5000) !== 8'hA5 || ram_byte(16'h5001) !== 8'h10) err = err + 1;
		$display("CP-300 test program: %0d errors", err);
		$display(err == 0 ? "PASS" : "FAIL");
	end else begin
		wr32(20'h00004, (MSEL) | 1 | 8'h40);   // hold the frame
		repeat (2000000) @(negedge clk);
		for (i = 0; i < 6144; i = i + 1) begin
			rd32(20'h30000 + 4 * i, w);
			for (x = 0; x < 8; x = x + 1) pix[8 * i + x] = w[4 * x +: 4];
		end
		f = $fopen("frame.ppm", "w");
		$fwrite(f, "P3\n256 192\n255\n");
		for (y = 0; y < 192; y = y + 1) begin
			for (x = 0; x < 256; x = x + 1) $fwrite(f, "%0d %0d %0d ", pal[pix[256 * y + x]][23:16], pal[pix[256 * y + x]][15:8], pal[pix[256 * y + x]][7:0]);
			$fwrite(f, "\n");
		end
		$fclose(f);
		$display("frame.ppm written");
	end
	$finish;
end

// activity counters (printed at the end)
integer n_ramw = 0, n_vw = 0, n_cen = 0, n_vx = 0, n_rx = 0;
// TRACE_MS > 0: a histogram of the opcode fetch addresses from TRACE_MS to TRACE_MS + 5, printed as address ranges at the end
integer hist [0:65535];
integer ha, hs;
initial for (ha = 0; ha < 65536; ha = ha + 1) hist[ha] = 0;
always @(negedge dut.z_rd_n) if (TRACE_MS > 0 && !dut.z_m1_n && !dut.z_mreq_n && $realtime > TRACE_MS * 1.0e6 && $realtime < (TRACE_MS + 5) * 1.0e6)
	hist[dut.z_a] = hist[dut.z_a] + 1;
task hist_print;
begin
	hs = -1;
	for (ha = 0; ha <= 65536; ha = ha + 1)
		if (ha < 65536 && hist[ha] > 0) begin if (hs < 0) hs = ha; end
		else if (hs >= 0) begin $display("fetched %h-%h (%0d at the start)", hs[15:0], ha[15:0] - 16'd1, hist[hs]); hs = -1; end
end
endtask
// the first undefined Z80 address: the last bus reads before it
reg  [25:0] lastr [0:11];                 // {mreq, iorq, address, data}
integer li, xs = 0;
always @(posedge dut.z_rd_n) if (!xs) begin
	for (li = 11; li > 0; li = li - 1) lastr[li] = lastr[li - 1];
	lastr[0] = {~dut.z_mreq_n, ~dut.z_iorq_n, dut.z_a, dut.z_di};
end
always @(posedge clk) if (!xs && ^dut.z_a === 1'bx && $realtime > 3.0e6) begin
	xs = 1;
	$display("%t the Z80's address is undefined; the reads before (newest first):", $time);
	for (li = 0; li < 12; li = li + 1) $display("  %s %h -> %h", lastr[li][25] ? "mem" : lastr[li][24] ? "io " : "?  ", lastr[li][23:8], lastr[li][7:0]);
end
always @(posedge clk) begin
	if (dut.ram_we) n_ramw = n_ramw + 1;
	if ((dut.x1_v_we && dut.mx) || (dut.mc_v_we && dut.mm)) n_vw = n_vw + 1;
	if (dut.z_cen) n_cen = n_cen + 1;
end
task vram_x;
	integer j;
	reg [9:0] q;
begin
	n_vx = 0;
	for (j = 0; j < 2048; j = j + 1) begin
		q = dut.pool.rs[0].rk[0].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[0].rk[1].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[0].rk[2].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[0].rk[3].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[1].rk[0].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[1].rk[1].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[1].rk[2].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
		q = dut.pool.rs[1].rk[3].blk.m[j]; if (^q[7:0] === 1'bx) n_vx = n_vx + 1;
	end
end
endtask

function [7:0] ram_byte(input [15:0] a);
	reg [9:0] q;
begin
	case (a[15:11])
	5'd0: q = dut.pool.rb[0].blk.m[a[10:0]];
	5'd1: q = dut.pool.rb[1].blk.m[a[10:0]];
	5'd2: q = dut.pool.rb[2].blk.m[a[10:0]];
	5'd3: q = dut.pool.rb[3].blk.m[a[10:0]];
	5'd4: q = dut.pool.rb[4].blk.m[a[10:0]];
	5'd5: q = dut.pool.rb[5].blk.m[a[10:0]];
	5'd6: q = dut.pool.rb[6].blk.m[a[10:0]];
	5'd7: q = dut.pool.rb[7].blk.m[a[10:0]];
	5'd8: q = dut.pool.rb[8].blk.m[a[10:0]];
	5'd9: q = dut.pool.rb[9].blk.m[a[10:0]];
	5'd10: q = dut.pool.rb[10].blk.m[a[10:0]];
	5'd11: q = dut.pool.rb[11].blk.m[a[10:0]];
	5'd12: q = dut.pool.rb[12].blk.m[a[10:0]];
	5'd13: q = dut.pool.rb[13].blk.m[a[10:0]];
	5'd14: q = dut.pool.rb[14].blk.m[a[10:0]];
	5'd15: q = dut.pool.rb[15].blk.m[a[10:0]];
	5'd16: q = dut.pool.rb[16].blk.m[a[10:0]];
	5'd17: q = dut.pool.rb[17].blk.m[a[10:0]];
	5'd18: q = dut.pool.rb[18].blk.m[a[10:0]];
	5'd19: q = dut.pool.rb[19].blk.m[a[10:0]];
	5'd20: q = dut.pool.rb[20].blk.m[a[10:0]];
	5'd21: q = dut.pool.rb[21].blk.m[a[10:0]];
	5'd22: q = dut.pool.rb[22].blk.m[a[10:0]];
	5'd23: q = dut.pool.rb[23].blk.m[a[10:0]];
	5'd24: q = dut.pool.rb[24].blk.m[a[10:0]];
	5'd25: q = dut.pool.rb[25].blk.m[a[10:0]];
	5'd26: q = dut.pool.rb[26].blk.m[a[10:0]];
	5'd27: q = dut.pool.rb[27].blk.m[a[10:0]];
	5'd28: q = dut.pool.rb[28].blk.m[a[10:0]];
	5'd29: q = dut.pool.rb[29].blk.m[a[10:0]];
	5'd30: q = dut.pool.rb[30].blk.m[a[10:0]];
	5'd31: q = dut.pool.rb[31].blk.m[a[10:0]];
	default: q = 10'h3FF;
	endcase
	ram_byte = q[7:0];
end
endfunction
// VDPDBG = 1: the MSX1's VDP port accesses (what the Z80 sends, what the vdp18 CPU interface does with it)
integer vd_n = 0;
reg dbg_busy = 1'b0;
always @(posedge clk) if (VDPDBG && dut.mx && dut.msx.vdp_sel && (!dut.z_wr_n || !dut.z_rd_n) && vd_n < 60 && !dbg_busy) begin
	dbg_busy <= 1'b1;
	vd_n = vd_n + 1;
	$display("%t VDP %s a0=%b data=%h  csw_n=%b csr_n=%b state=%0d wait=%b vram_we=%b", $time, dut.z_wr_n ? "RD" : "WR", dut.z_a[0], dut.z_do,
		~(dut.msx.vdp_sel & ~dut.z_wr_n), ~(dut.msx.vdp_sel & ~dut.z_rd_n), dut.msx.vdp.cpu_io_b.state_q, dut.msx.vdp_wait, dut.msx.vram_we);
end
always @(posedge dut.z_wr_n or posedge dut.z_rd_n) dbg_busy <= 1'b0;
always @(posedge clk) if (VDPDBG && dut.mx && dut.msx.vram_we && vd_n < 200) begin vd_n = vd_n + 1; $display("%t VRAM WE a=%h d=%h", $time, dut.msx.vram_a, dut.msx.v_wd); end

endmodule
