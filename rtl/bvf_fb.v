//
// CP-300 FPGA, BeagleV-Fire: frame capture. The picture of the running machine is stored in a frame RAM the
// host can read, with a frame counter.
//
// CP-300 (m4 = 0): the core's 512 x 192 picture, 1 bit per pixel, 12 KB. Word layout (32 bit, little endian
// host): word = y * 16 + x / 32; pixel x is bit (x mod 32), so the leftmost pixel is the least significant bit.
// BUFS = 2 keeps two frames (buffer select = word address bit 12): the host reads buffer `latest`, the writer
// fills the other one. The host checks frame_cnt before and after the copy and drops the copy if the counter
// moved on by 2 or more.
//
// CP-400 (m4 = 1): the 6847's 256 x 192 picture, 4 bits per pixel (a colour index, see idx4), 24 KB: word =
// y * 32 + x / 8, pixel x is nibble (x mod 8), the leftmost pixel in the least significant nibble. The 24 KB
// are the same RAM as the two CP-300 buffers, so there is ONE buffer and the host takes it with `hold`:
// while hold = 1 no new frame is started; `latest` is 1 when no frame is being written. The host sets hold,
// waits for latest, reads the words 0..6143, clears hold.
// The MSX1 and the Spectrum use the same path (m4 = 1, p4_direct = 1): their 256 x 192 picture as colour indexes (0..15).
//
module bvf_fb #(parameter BUFS = 2) (
	input             clk,
	input             m4,             // 1: the CP-400 picture
	// CP-300 (1 bit)
	input             pxen,
	input             screen,
	input             ink,
	input             vs_n,
	// CP-400 (6847 VGA output)
	input             p4_ena,         // pixel clock enable
	input             p4_hb,
	input             p4_vb,
	input       [5:0] p4_rgb,         // {r, g, b} 2 bits each, valid one clock after p4_ena
	input             p4_direct,      // MSX1, Spectrum: p4_rgb[3:0] is the colour index, one line per picture line (not two)
	input             hold,

	input      [12:0] h_addr,
	output     [31:0] h_dout,       // one clock after h_addr

	// the frame RAM (3 x 2K x 32 bit) is in bvf_pool: write port, read port (one clock of latency)
	output            fbm_we,
	output     [12:0] fbm_wa,
	output     [31:0] fbm_wd,
	output     [12:0] fbm_ra,
	input      [31:0] fbm_rq,

	output reg [15:0] frame_cnt,
	output            latest
);

reg [31:0] sh;
reg  [8:0] x;
reg  [7:0] y;
reg        scr_d;
reg        wbuf = 1'b0;
reg        lat  = 1'b0;

// --- CP-400 capture
reg        en_d, hb_d, vb_d, hb_p, vb_p, p4_writing;
reg  [8:0] col;
reg  [8:0] lin;                       // active VGA line (2 per picture line)
reg [31:0] sh4;
reg  [3:0] idx4;

// the 11 colours of the 6847 (map_palette): black, green, yellow, blue, red, white, cyan, magenta, orange,
// dark green, dark orange (text background)
always @(*) begin
	case (p4_rgb)
	6'b001100: idx4 = 4'd1;
	6'b111100: idx4 = 4'd2;
	6'b000011: idx4 = 4'd3;
	6'b110000: idx4 = 4'd4;
	6'b111111: idx4 = 4'd5;
	6'b001111: idx4 = 4'd6;
	6'b110011: idx4 = 4'd7;
	6'b111000: idx4 = 4'd8;
	6'b000100: idx4 = 4'd9;
	6'b010100: idx4 = 4'd10;
	default:   idx4 = 4'd0;
	endcase
end

initial begin frame_cnt = 16'd0; y = 8'd0; x = 9'd0; sh = 32'd0; scr_d = 1'b0;
	en_d = 1'b0; hb_d = 1'b1; vb_d = 1'b1; hb_p = 1'b1; vb_p = 1'b1; p4_writing = 1'b0; col = 9'd0; lin = 9'd0; sh4 = 32'd0; end

wire        wr_ok  = pxen && screen && (y < 8'd192) && (x[4:0] == 5'd31);
wire [12:0] waddr  = ((BUFS == 2 && wbuf) ? 13'd3072 : 13'd0) + {1'b0, y[7:0], 4'd0} + {4'd0, x[8:5]};
wire [12:0] raddr  = m4 ? h_addr : ((BUFS == 2 && h_addr[12]) ? 13'd3072 + {1'b0, h_addr[11:0]} : {1'b0, h_addr[11:0]});

// a pixel of the active picture on an even VGA line, one clock after its enable
wire        act_d  = en_d && !hb_d && !vb_d;
wire        wr4    = p4_writing && act_d && (p4_direct || !lin[0]) && (col[2:0] == 3'd7) && (col < 9'd256);
wire  [7:0] pline  = p4_direct ? lin[7:0] : lin[8:1];      // picture line (0..191)
wire [12:0] waddr4 = {pline, 5'd0} + {5'd0, col[7:3]};
wire [31:0] wdata4 = {(p4_direct ? p4_rgb[3:0] : idx4), sh4[31:4]};

always @(posedge clk) begin
	if (!m4) begin
		if (pxen) begin
			scr_d <= screen;
			if (!vs_n) y <= 8'd0;
			else if (scr_d && !screen && y != 8'd255) y <= y + 8'd1;

			if (screen) x <= x + 9'd1; else x <= 9'd0;

			if (screen) sh <= {ink, sh[31:1]};

			// last line finished: the frame is complete
			if (scr_d && !screen && y == 8'd191) begin
				lat       <= wbuf;
				frame_cnt <= frame_cnt + 16'd1;
				if (BUFS == 2) wbuf <= ~wbuf;
			end
		end
		p4_writing <= 1'b0;
	end else begin
		en_d <= p4_ena;
		hb_d <= p4_hb;
		vb_d <= p4_vb;
		if (act_d) begin
			sh4 <= wdata4;
			col <= col + 9'd1;
		end
		if (p4_ena) begin
			hb_p <= p4_hb;
			vb_p <= p4_vb;
			// end of an active line: the next one
			if (!hb_p && p4_hb) begin
				col <= 9'd0;
				if (!p4_vb) lin <= lin + 9'd1;
			end
			// start of the picture: take it unless the host holds the buffer
			if (vb_p && !p4_vb) begin
				lin <= 9'd0;
				col <= 9'd0;
				p4_writing <= !hold;
			end
			// end of the picture
			if (!vb_p && p4_vb) begin
				if (p4_writing) frame_cnt <= frame_cnt + 16'd1;
				p4_writing <= 1'b0;
			end
		end
	end
end

assign fbm_we = m4 ? wr4 : (wr_ok & ~m4);
assign fbm_wa = m4 ? waddr4 : waddr;
assign fbm_wd = m4 ? wdata4 : {ink, sh[31:1]};
assign fbm_ra = raddr;
assign h_dout = fbm_rq;

assign latest = m4 ? !p4_writing : lat;

endmodule
