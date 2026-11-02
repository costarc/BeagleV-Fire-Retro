--
-- CP-400 / TRS-80 Color Computer 2 core for the BeagleV-Fire (the machine of the multi-machine bitstream).
--
-- This is the board-independent part of the "platform" of CP400_COLOR_FPGA (Victor Trucco's Multicore core,
-- based on Mark McDougall's PACE): MC6809 (cpu09), MC6883 SAM, MC6847 VDG, two MC6821 PIAs, the address
-- decoder and the ROMs. What the original took from the board is replaced:
--
--   clock       the original runs on 57.272 MHz with a 14.318 MHz enable. Here everything runs on the 42 MHz
--               core clock with an enable of exactly 14.318181 MHz (15/44 of the clock: ena14), so the machine
--               has its real speed (NTSC, 60 Hz).
--   RAM         the 64 KB of external SRAM: a port (ram_a / ram_we / ram_d / ram_q, one clock latency) to
--               the RAM shared with the CP-300.
--   ROMs        Color BASIC and Extended BASIC are RAMs loaded by the host (the images are not part of the
--               bitstream): words 0-2047 of the ROM load window = Extended BASIC ($8000-$9FFF), words
--               2048-4095 = Color BASIC ($A000-$BFFF), 4096-6143 = the cartridge ($C000-$DFFF, mirrored up to $FEFF:
--               the MiniIDE DOS), big endian packed like the CP-300's ROM.
--   cartridge   with cart_en the cartridge ROM is there and the CART line carries Q (the ROM auto-starts as on a
--               real cartridge); without it the port reads as empty.
--   hard disk   the CPU bus of $FF50-$FF5F goes out (ide_*) to bvf_ide, which answers it.
--   keyboard    keys(8 * n + i): column n (PIA B bit n, active low select), row i (PIA A bit i), 1 = pressed.
--   video       the VGA style output of the 6847 as the frame capture needs it.
--   no cartridge, no IDE, no cassette, joysticks centred.
--
-- Copyright of the parts: see the headers of the files in this folder (BSD style for the Multicore parts,
-- GPL for cpu09 by John Kent).
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cp400_core is
	port (
		clk       : in  std_logic;                       -- 42 MHz
		reset     : in  std_logic;                       -- high: the machine is held

		keys      : in  std_logic_vector(63 downto 0);

		rl_we     : in  std_logic;                       -- ROM load, one word per clk
		rl_waddr  : in  std_logic_vector(12 downto 0);
		rl_wdata  : in  std_logic_vector(31 downto 0);

		ram_a     : out std_logic_vector(15 downto 0);   -- read address (the SAM's)
		ram_q     : in  std_logic_vector(7 downto 0);    -- one clock later
		ram_we    : out std_logic;                       -- write: one clk pulse after the end of the SAM's write pulse
		ram_wa    : out std_logic_vector(15 downto 0);
		ram_d     : out std_logic_vector(7 downto 0);

		cap_ena   : out std_logic;                       -- pixel clock enable of the VGA output (14.318 MHz)
		cap_hb    : out std_logic;                       -- not the active picture
		cap_vb    : out std_logic;
		cap_rgb   : out std_logic_vector(5 downto 0);    -- r(1:0) g(1:0) b(1:0), one clk after the enables
		cap_fs_n  : out std_logic;                       -- the 6847's field sync (low in the vertical blanking)

		audio     : out std_logic_vector(8 downto 0);

		cass_in    : in  std_logic := '0';               -- the cassette: PIA 1 port A bit 0
		cass_out   : out std_logic;                      -- the DAC's top bit (the CoCo records through the DAC)
		cass_motor : out std_logic;                      -- PIA 1 CA2

		cart_en   : in  std_logic;
		-- the cartridge ROM (2K x 32 bit) is in bvf_pool: write port and read port (one clock of latency)
		cart_we   : out std_logic;
		cart_wa   : out std_logic_vector(10 downto 0);
		cart_wd   : out std_logic_vector(31 downto 0);
		cart_ra   : out std_logic_vector(10 downto 0);
		cart_rq   : in  std_logic_vector(31 downto 0);
		-- the BASIC and extended BASIC ROMs (2 x 2K x 32 bit) are in bvf_pool too: rom_wa(11) = 1 BASIC, 0 extended BASIC;
		-- one read address for both, rom_rq = {BASIC, extended BASIC} one clock later
		rom_we    : out std_logic;
		rom_wa    : out std_logic_vector(11 downto 0);
		rom_wd    : out std_logic_vector(31 downto 0);
		rom_ra    : out std_logic_vector(10 downto 0);
		rom_rq    : in  std_logic_vector(63 downto 0);
		ide_cs    : out std_logic;                       -- the CPU address is $FF5x
		dbg_a     : out std_logic_vector(15 downto 0);   -- the 6809's address (a debug register of the host)
		fdc_cs    : out std_logic;                       -- the CPU address is $FF4x (the floppy controller: bus signals as for the IDE)
		fdc_q     : in  std_logic_vector(7 downto 0);
		fdc_halt  : in  std_logic;                       -- DRQ halt of the disk controller: the 6809 stops after the instruction
		fdc_nmi   : in  std_logic;                       -- INTRQ (double density) as NMI
		ide_cyc_end : out std_logic;                     -- one clk at the end of a CPU cycle (E falling)
		ide_rw    : out std_logic;                       -- 1 = read
		ide_a     : out std_logic_vector(3 downto 0);
		ide_d     : out std_logic_vector(7 downto 0);
		ide_q     : in  std_logic_vector(7 downto 0)
	);
end entity cp400_core;

architecture rtl of cp400_core is

	-- clock enables
	signal acc          : unsigned(5 downto 0) := (others => '0');
	signal ena14        : std_logic := '0';
	signal e_r          : std_logic := '0';
	signal cpu_ena      : std_logic := '0';

	-- resets
	signal rst_cnt      : unsigned(4 downto 0) := (others => '0');
	signal cpu_rst      : std_logic := '1';

	-- SAM and RAM
	signal clk_e, clk_q : std_logic;
	signal ma           : std_logic_vector(7 downto 0);
	signal ras_n        : std_logic;
	signal cas_n        : std_logic;
	signal sam_we_n     : std_logic;
	signal sam_a        : std_logic_vector(15 downto 0) := (others => '0');
	signal cs_sel       : std_logic_vector(2 downto 0);
	signal vdgclk       : std_logic;
	signal sam_dbg      : std_logic_vector(15 downto 0);
	signal ram_datao    : std_logic_vector(7 downto 0) := (others => '0');
	signal wa_d         : std_logic_vector(15 downto 0) := (others => '0');
	signal wd_d         : std_logic_vector(7 downto 0) := (others => '0');
	signal vdg_data     : std_logic_vector(7 downto 0) := (others => '0');

	-- CPU
	signal cpu_a        : std_logic_vector(15 downto 0);
	signal cpu_d_i      : std_logic_vector(7 downto 0);
	signal cpu_d_o      : std_logic_vector(7 downto 0);
	signal cpu_r_wn     : std_logic;
	signal cpu_vma      : std_logic;
	signal cpu_irq      : std_logic;
	signal cpu_firq     : std_logic;

	-- selects
	signal ram_rd, extrom_cs, rom_cs, cart_cs, pia_0_cs, pia_1_cs : std_logic;
	signal pia_0_datao  : std_logic_vector(7 downto 0);
	signal pia_1_datao  : std_logic_vector(7 downto 0);

	-- ROMs
	signal cart_w       : std_logic_vector(31 downto 0);
	signal cart_datao   : std_logic_vector(7 downto 0);
	signal ext_w, bas_w : std_logic_vector(31 downto 0);
	signal ext_datao    : std_logic_vector(7 downto 0);
	signal rom_datao    : std_logic_vector(7 downto 0);
	signal lane_q       : std_logic_vector(1 downto 0);

	-- VDG
	signal hs_n, fs_n, da0 : std_logic;
	signal vdg_css      : std_logic;
	signal vdg_intn_ext : std_logic;
	signal vdg_gm       : std_logic_vector(2 downto 0);
	signal vdg_an_g     : std_logic;
	signal r_s, g_s, b_s : std_logic_vector(7 downto 0);

	-- PIA signals
	signal irqa0, irqb0, irqa1, irqb1 : std_logic;
	signal pa_i0        : std_logic_vector(7 downto 0);
	signal pb_o0        : std_logic_vector(7 downto 0);
	signal pa_i1, pa_o1 : std_logic_vector(7 downto 0);
	signal pb_i1, pb_o1 : std_logic_vector(7 downto 0);
	signal sel          : std_logic_vector(2 downto 1);
	signal snden        : std_logic;
	signal cassmot      : std_logic;
	signal dac_data     : std_logic_vector(5 downto 0);
	signal sndout       : std_logic;
	signal joyin        : std_logic;
	signal cart_n       : std_logic;
	signal ide_sel      : std_logic;
	signal fdc_sel      : std_logic;

begin

	-- 14.318181 MHz = 15/44 of 42 MHz, exactly
	process (clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then
				acc <= (others => '0');
				ena14 <= '0';
			elsif acc >= 29 then
				acc <= acc - 29;
				ena14 <= '1';
			else
				acc <= acc + 15;
				ena14 <= '0';
			end if;
		end if;
	end process;

	-- the CPU acts where the original's gated clock (not E) fell: the rising edge of E. The SAM takes the CPU
	-- address on the very next 14 MHz tick, so the CPU has to update on the first clk of E (no register here).
	process (clk)
	begin
		if rising_edge(clk) then
			e_r <= clk_e;
		end if;
	end process;
	cpu_ena <= clk_e and not e_r;

	-- the CPU reset is held 32 E cycles longer than the machine reset
	process (clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then
				rst_cnt <= (others => '0');
				cpu_rst <= '1';
			elsif cpu_ena = '1' then
				if rst_cnt = 31 then
					cpu_rst <= '0';
				else
					rst_cnt <= rst_cnt + 1;
				end if;
			end if;
		end if;
	end process;

	-- RAM address from the SAM's multiplexed address, and the data latches (as in the original platform)
	process (clk)
		variable ras_n_r : std_logic := '0';
		variable cas_n_r : std_logic := '0';
		variable q_r     : std_logic := '0';
	begin
		if rising_edge(clk) then
			if reset = '1' then
				ras_n_r := '0'; cas_n_r := '0'; q_r := '0';
			elsif ena14 = '1' then
				if ras_n = '1' and ras_n_r = '0' and clk_e = '1' then
					ram_datao <= ram_q;
				end if;
				if ras_n = '0' and ras_n_r = '1' then
					sam_a(7 downto 0) <= ma;
				elsif cas_n = '0' and cas_n_r = '1' then
					sam_a(15 downto 8) <= ma;
				end if;
				if clk_q = '1' and q_r = '0' then
					vdg_data <= ram_q;
				end if;
				ras_n_r := ras_n;
				cas_n_r := cas_n;
				q_r := clk_q;
			end if;
		end if;
	end process;

	-- the SRAM of the original writes at the END of the write pulse, with the address and data of its last
	-- clocks (the SAM changes the address during the pulse): write once, as the pulse ends
	ram_a <= sam_a;
	process (clk)
		variable we_d : std_logic := '0';
	begin
		if rising_edge(clk) then
			ram_we <= we_d and sam_we_n;
			ram_wa <= wa_d;
			ram_d  <= wd_d;
			wa_d <= sam_a;
			wd_d <= cpu_d_o;
			we_d := not sam_we_n;
		end if;
	end process;

	cpu_d_i <= pia_0_datao when pia_0_cs = '1' else
	           pia_1_datao when pia_1_cs = '1' else
	           rom_datao   when rom_cs = '1' else
	           ext_datao   when extrom_cs = '1' else
	           cart_datao  when cart_cs = '1' and cart_en = '1' else
	           ide_q       when ide_sel = '1' else
	           fdc_q       when fdc_sel = '1' else
	           ram_datao   when ram_rd = '1' else
	           x"FF";

	cpu : entity work.cpu09
		port map (
			clk => clk, ena => cpu_ena, rst => cpu_rst,
			rw => cpu_r_wn, vma => cpu_vma, addr => cpu_a,
			data_in => cpu_d_i, data_out => cpu_d_o,
			halt => fdc_halt, hold => '0', irq => cpu_irq, firq => cpu_firq, nmi => fdc_nmi
		);

	sam : entity work.mc6883
		port map (
			clk => clk, clk_ena => ena14, reset => reset,
			a => cpu_a, rw_n => cpu_r_wn,
			da0 => da0, hs_n => hs_n, vclk => vdgclk,
			s => cs_sel, e => clk_e, q => clk_q, z => ma,
			ras0_n => ras_n, cas_n => cas_n, we_n => sam_we_n, dbg => sam_dbg
		);

	-- the 74LS138 of the original: S selects one of the eight
	ram_rd    <= '1' when cs_sel = "000" else '0';
	extrom_cs <= '1' when cs_sel = "001" else '0';
	rom_cs    <= '1' when cs_sel = "010" else '0';
	cart_cs   <= '1' when cs_sel = "011" else '0';
	pia_0_cs  <= '1' when cs_sel = "100" else '0';
	pia_1_cs  <= '1' when cs_sel = "101" else '0';

	vdg : entity work.mc6847
		generic map (T1_VARIANT => false, CHAR_ROM_FILE => "", CVBS_NOT_VGA => false)
		port map (
			clk => clk, clk_ena => ena14, reset => reset,
			da0 => da0, dd => vdg_data, hs_n => hs_n, fs_n => fs_n,
			an_g => vdg_an_g, an_s => vdg_data(7), intn_ext => vdg_intn_ext,
			gm => vdg_gm, css => vdg_css, inv => vdg_data(6),
			red => r_s, green => g_s, blue => b_s, hsync => open, vsync => open,
			hblank => open, vblank => open,
			artifact_en => '0', artifact_set => '0', artifact_phase => "00",
			cvbs => open,
			cap_hb => cap_hb, cap_vb => cap_vb, cap_ena => cap_ena
		);

	cap_rgb  <= r_s(7 downto 6) & g_s(7 downto 6) & b_s(7 downto 6);
	cap_fs_n <= fs_n;

	-- ROMs: a word per write, read as bytes (big endian: the first byte in bits 31:24)
	process (clk)
	begin
		if rising_edge(clk) then
			lane_q <= cpu_a(1 downto 0);
		end if;
	end process;
	rom_we <= rl_we and not rl_waddr(12);
	rom_wa <= rl_waddr(11 downto 0);
	rom_wd <= rl_wdata;
	rom_ra <= cpu_a(12 downto 2);
	bas_w  <= rom_rq(63 downto 32);
	ext_w  <= rom_rq(31 downto 0);

	cart_we <= rl_we and rl_waddr(12);
	cart_wa <= rl_waddr(10 downto 0);
	cart_wd <= rl_wdata;
	cart_ra <= cpu_a(12 downto 2);
	cart_w  <= cart_rq;

	with lane_q select
		ext_datao <= ext_w(31 downto 24) when "00",
		             ext_w(23 downto 16) when "01",
		             ext_w(15 downto 8)  when "10",
		             ext_w(7 downto 0)   when others;
	with lane_q select
		cart_datao <= cart_w(31 downto 24) when "00",
		              cart_w(23 downto 16) when "01",
		              cart_w(15 downto 8)  when "10",
		              cart_w(7 downto 0)   when others;
	with lane_q select
		rom_datao <= bas_w(31 downto 24) when "00",
		             bas_w(23 downto 16) when "01",
		             bas_w(15 downto 8)  when "10",
		             bas_w(7 downto 0)   when others;

	-- PIA 0: keyboard and the sync interrupts
	cpu_irq <= irqa0 or irqb0;

	process (clk)
		variable k : std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) then
			k := (others => '0');
			for n in 0 to 7 loop
				if pb_o0(n) = '0' then
					k := k or keys(8 * n + 7 downto 8 * n);
				end if;
			end loop;
			-- key inputs are active low; bit 7 is the joystick comparator
			pa_i0 <= joyin & not k(6 downto 0);
		end if;
	end process;

	-- joysticks centred: the comparator answers 1 while the DAC is at or below the centre
	joyin <= '1' when unsigned(dac_data) <= 31 else '0';

	pia0 : entity work.pia6821
		port map (
			sysclk => clk, ena => ena14, rst => reset, cs => pia_0_cs, rw => cpu_r_wn, addr => cpu_a(1 downto 0),
			data_in => cpu_d_o, data_out => pia_0_datao, irqa => irqa0, irqb => irqb0,
			pa_i => pa_i0, pa_o => open, pa_oe => open,
			ca1 => hs_n, ca2_i => '0', ca2_o => sel(1), ca2_oe => open,
			pb_i => (others => '0'), pb_o => pb_o0, pb_oe => open,
			cb1 => fs_n, cb2_i => '0', cb2_o => sel(2), cb2_oe => open
		);

	-- PIA 1: sound, VDG mode, cassette (unused), serial (unused)
	pa_i1 <= (0 => cass_in, others => '0');
	cass_out   <= dac_data(5);
	cass_motor <= cassmot;
	dac_data <= pa_o1(7 downto 2);
	sndout   <= pb_o1(1);
	pb_i1    <= "00000100";           -- bit 2: the 32K RAM jumper
	vdg_css      <= pb_o1(3);
	vdg_intn_ext <= pb_o1(4);
	vdg_gm       <= pb_o1(6 downto 4);
	vdg_an_g     <= pb_o1(7);
	cpu_firq <= irqa1 or irqb1;
	-- the CART line carries Q only with a cartridge in (without one it stays high: spurious FIRQs restart the ROM)
	cart_n   <= clk_q when cart_en = '1' else '1';

	-- the hard disk at $FF50-$FF5F: the CPU bus out, the cycle strobe at the end of E
	ide_sel     <= '1' when cpu_a(15 downto 4) = x"FF5" else '0';
	ide_cs      <= ide_sel;
	fdc_sel     <= '1' when cpu_a(15 downto 4) = x"FF4" else '0';
	fdc_cs      <= fdc_sel;
	dbg_a       <= cpu_a;
	ide_cyc_end <= e_r and not clk_e;
	ide_rw      <= cpu_r_wn;
	ide_a       <= cpu_a(3 downto 0);
	ide_d       <= cpu_d_o;

	pia1 : entity work.pia6821
		port map (
			sysclk => clk, ena => ena14, rst => reset, cs => pia_1_cs, rw => cpu_r_wn, addr => cpu_a(1 downto 0),
			data_in => cpu_d_o, data_out => pia_1_datao, irqa => irqa1, irqb => irqb1,
			pa_i => pa_i1, pa_o => pa_o1, pa_oe => open,
			ca1 => '0', ca2_i => '0', ca2_o => cassmot, ca2_oe => open,
			pb_i => pb_i1, pb_o => pb_o1, pb_oe => open,
			cb1 => cart_n, cb2_i => '0', cb2_o => snden, cb2_oe => open
		);

	-- sound: the 6-bit DAC, or the 1-bit sound (as the original's mux, without the cassette)
	process (clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then
				audio <= (others => '0');
			elsif snden = '1' then
				if sel = "00" then
					audio <= dac_data & "000";
				else
					audio <= (others => '0');
				end if;
			else
				audio <= sndout & "00000000";
			end if;
		end if;
	end process;

end architecture rtl;
