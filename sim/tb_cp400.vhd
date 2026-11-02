-- Testbench of cp400_core (ModelSim): loads the two ROM images, runs the machine and dumps the captured
-- frames as text (one line per picture line, one hex digit per pixel = r g b quantised: see cap_rgb).
--
--   vsim -c tb_cp400 -gROM_BAS=... -gROM_EXT=... -gFRAMES=40
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_cp400 is
	generic (
		ROM_BAS : string := "cp400bas.hex";
		ROM_EXT : string := "cp400extbas.hex";
		SEC_FILE : string := "";                -- sectors served on reads: lines "LBA w0 w1 ... w127" (32 bit hex words, little endian bytes)
		ID_FILE : string := "";                 -- the IDENTIFY data (256 hex words, one per line)
		ROM_CART : string := "";                -- the MiniIDE DOS cartridge (empty: no cartridge, no disk)
		OUT_FILE : string := "cp400_frames.txt";
		FRAMES  : integer := 40;
		TRACE_FROM : time := 14287 us;
		CPU_TRACE_FROM : time := 3000 ms;
		KEY_AT : time := 2700 ms;
		TYPE_TEXT : string := "HI"
	);
end entity;

architecture sim of tb_cp400 is
	signal clk      : std_logic := '0';
	signal reset    : std_logic := '1';
	signal keys     : std_logic_vector(63 downto 0) := (others => '0');
	signal rl_we    : std_logic := '0';
	signal rl_waddr : std_logic_vector(12 downto 0) := (others => '0');
	signal rl_wdata : std_logic_vector(31 downto 0) := (others => '0');
	signal ram_a    : std_logic_vector(15 downto 0);
	signal ram_we   : std_logic;
	signal ram_wa   : std_logic_vector(15 downto 0);
	signal ram_d    : std_logic_vector(7 downto 0);
	signal ram_q    : std_logic_vector(7 downto 0) := (others => '0');
	signal cap_ena, cap_hb, cap_vb, cap_fs_n : std_logic;
	signal cap_rgb  : std_logic_vector(5 downto 0);
	signal audio    : std_logic_vector(8 downto 0);
	signal cart_we : std_logic;
	signal cart_wa, cart_ra : std_logic_vector(10 downto 0);
	signal cart_wd, cart_rq : std_logic_vector(31 downto 0) := (others => '0');
	type cart_t is array (0 to 2047) of std_logic_vector(31 downto 0);
	signal cart_mem : cart_t := (others => (others => '0'));
	signal rom_we : std_logic;
	signal rom_wa : std_logic_vector(11 downto 0);
	signal rom_ra : std_logic_vector(10 downto 0);
	signal rom_wd : std_logic_vector(31 downto 0);
	signal rom_rq : std_logic_vector(63 downto 0) := (others => '0');
	signal pm_bas, pm_ext : cart_t := (others => (others => '0'));
	signal cart_en, ide_cs, ide_cyc_end, ide_rw : std_logic := '0';
	signal ide_a    : std_logic_vector(3 downto 0);
	signal ide_d, ide_q : std_logic_vector(7 downto 0);
	signal ide_present : std_logic := '0';
	signal ide_pending, ide_ack_we, ide_we : std_logic := '0';
	signal ide_req, ide_lba, ide_ackw, ide_hdout, ide_wdata : std_logic_vector(31 downto 0) := (others => '0');
	signal ide_haddr : std_logic_vector(6 downto 0) := (others => '0');
	signal ide_reqs : integer := 0;
	signal ide_cmds : integer := 0;
	type idw_t is array (0 to 255) of std_logic_vector(15 downto 0);
	type secd_t is array (0 to 639, 0 to 127) of std_logic_vector(31 downto 0);
	type secl_t is array (0 to 639) of integer;

	type ram_t is array (0 to 65535) of std_logic_vector(7 downto 0);
	signal ram : ram_t := (others => x"00");
	type rom_t is array (0 to 8191) of std_logic_vector(7 downto 0);

	impure function load_hex(name : string) return rom_t is
		file f : text open read_mode is name;
		variable l : line;
		variable r : rom_t := (others => x"FF");
		variable ch : character;
		variable n, a, t : integer;
		function hx(c : character) return integer is
		begin
			if c >= '0' and c <= '9' then return character'pos(c) - 48;
			elsif c >= 'A' and c <= 'F' then return character'pos(c) - 55;
			else return character'pos(c) - 87; end if;
		end function;
		variable p : integer;
		variable s : string(1 to 600);
		variable len : integer;
	begin
		while not endfile(f) loop
			readline(f, l);
			len := l'length;
			if len > 10 and l(l'left) = ':' then
				s(1 to len) := l.all;
				n := hx(s(2)) * 16 + hx(s(3));
				a := ((hx(s(4)) * 16 + hx(s(5))) * 256) + hx(s(6)) * 16 + hx(s(7));
				t := hx(s(8)) * 16 + hx(s(9));
				if t = 0 then
					for i in 0 to n - 1 loop
						p := 10 + 2 * i;
						r(a + i) := std_logic_vector(to_unsigned(hx(s(p)) * 16 + hx(s(p + 1)), 8));
					end loop;
				end if;
			end if;
		end loop;
		return r;
	end function;

begin
	clk <= not clk after 11.905 ns;   -- 42 MHz

	-- the shared 64 KB RAM: write while we is high, one clock read latency
	process (clk)
	begin
		if rising_edge(clk) then
			if ram_we = '1' then
				ram(to_integer(unsigned(ram_wa))) <= ram_d;
			end if;
			ram_q <= ram(to_integer(unsigned(ram_a)));
		end if;
	end process;

	-- the cartridge ROM (a block of bvf_pool on chip)
	process (clk)
	begin
		if rising_edge(clk) then
			if cart_we = '1' then
				cart_mem(to_integer(unsigned(cart_wa))) <= cart_wd;
			end if;
			cart_rq <= cart_mem(to_integer(unsigned(cart_ra)));
		end if;
	end process;

	-- the BASIC and extended BASIC ROMs (blocks of bvf_pool)
	process (clk)
	begin
		if rising_edge(clk) then
			if rom_we = '1' then
				if rom_wa(11) = '1' then pm_bas(to_integer(unsigned(rom_wa(10 downto 0)))) <= rom_wd;
				else pm_ext(to_integer(unsigned(rom_wa(10 downto 0)))) <= rom_wd; end if;
			end if;
			rom_rq <= pm_bas(to_integer(unsigned(rom_ra))) & pm_ext(to_integer(unsigned(rom_ra)));
		end if;
	end process;

	dut : entity work.cp400_core
		port map (clk => clk, reset => reset, keys => keys,
		          rl_we => rl_we, rl_waddr => rl_waddr, rl_wdata => rl_wdata,
		          ram_a => ram_a, ram_we => ram_we, ram_wa => ram_wa, ram_d => ram_d, ram_q => ram_q,
		          cap_ena => cap_ena, cap_hb => cap_hb, cap_vb => cap_vb, cap_rgb => cap_rgb, cap_fs_n => cap_fs_n,
		          audio => audio,
		          cart_en => cart_en, cart_we => cart_we, cart_wa => cart_wa, cart_wd => cart_wd, cart_ra => cart_ra, cart_rq => cart_rq, rom_we => rom_we, rom_wa => rom_wa, rom_wd => rom_wd, rom_ra => rom_ra, rom_rq => rom_rq, ide_cs => ide_cs, ide_cyc_end => ide_cyc_end, ide_rw => ide_rw,
		          ide_a => ide_a, ide_d => ide_d, ide_q => ide_q);

	-- the hard disk (Verilog) and a host model: identify gives zeros with a capacity, reads give zeros, writes are taken
	ide : entity work.bvf_ide
		port map (clk => clk, reset => reset, present => ide_present, cs => ide_cs, cyc_end => ide_cyc_end, rw => ide_rw,
		          a => ide_a, din => ide_d, dout => ide_q, pending => ide_pending, req_word => ide_req, lba_word => ide_lba,
		          ack_word => ide_ackw, ack_we => ide_ack_we, wdata => ide_wdata, h_addr => ide_haddr, h_we => ide_we,
		          h_dout => ide_hdout);

	process
		file f : text open write_mode is "cp400_ide.txt";
		variable l : line;
		variable idw : idw_t := (others => x"0000");
		file fi : text;
		variable li : line;
		variable k : integer := 0;
		variable hv : std_logic_vector(15 downto 0);
		variable secd : secd_t;
		variable secl : secl_t := (others => -1);
		variable nsec : integer := 0;
		variable lbav : integer;
		variable w32 : std_logic_vector(31 downto 0);
		variable found : integer;
	begin
		if SEC_FILE'length > 0 then
			file_open(fi, SEC_FILE, read_mode);
			while not endfile(fi) and nsec < 640 loop
				readline(fi, li); read(li, lbav);
				secl(nsec) := lbav;
				for w in 0 to 127 loop hread(li, w32); secd(nsec, w) := w32; end loop;
				nsec := nsec + 1;
			end loop;
			file_close(fi);
		end if;
		if ID_FILE'length > 0 then
			file_open(fi, ID_FILE, read_mode);
			while not endfile(fi) and k < 256 loop
				readline(fi, li); hread(li, hv); idw(k) := hv; k := k + 1;
			end loop;
			file_close(fi);
		end if;
		wait until reset = '0';
		loop
			wait until rising_edge(clk) and ide_pending = '1';
			ide_reqs <= ide_reqs + 1;
			write(l, string'("request ")); write(l, to_hstring(ide_req)); write(l, string'(" lba ")); write(l, to_hstring(ide_lba));
			write(l, string'(" at ")); write(l, time'image(now)); writeline(f, l);
			found := -1;
			for q in 0 to 639 loop
				if secl(q) = to_integer(unsigned(ide_lba(27 downto 0))) then found := q; end if;
			end loop;
			if ide_req(1 downto 0) = "01" or ide_req(1 downto 0) = "11" then
				for w in 0 to 127 loop
					wait until rising_edge(clk);
					ide_we <= '1'; ide_haddr <= std_logic_vector(to_unsigned(w, 7));
					ide_wdata <= x"00000000";
					if ide_req(0) = '1' and found >= 0 then ide_wdata <= secd(found, w); end if;
					if ide_req(1 downto 0) = "11" then ide_wdata <= idw(2 * w + 1) & idw(2 * w); end if;
				end loop;
				wait until rising_edge(clk);
				ide_we <= '0';
			end if;
			wait until rising_edge(clk);
			ide_ack_we <= '1'; ide_wdata <= x"00000001";
			wait until rising_edge(clk);
			ide_ack_we <= '0';
			wait for 2 us;
		end loop;
	end process;

	-- load the ROMs, then release the reset
	process
		variable bas, ext, cart : rom_t;
	begin
		bas := load_hex(ROM_BAS);
		ext := load_hex(ROM_EXT);
		wait for 1 us;
		for i in 0 to 2047 loop
			wait until rising_edge(clk);
			rl_we <= '1'; rl_waddr <= std_logic_vector(to_unsigned(i, 13));
			rl_wdata <= ext(4 * i) & ext(4 * i + 1) & ext(4 * i + 2) & ext(4 * i + 3);
		end loop;
		for i in 0 to 2047 loop
			wait until rising_edge(clk);
			rl_we <= '1'; rl_waddr <= std_logic_vector(to_unsigned(2048 + i, 13));
			rl_wdata <= bas(4 * i) & bas(4 * i + 1) & bas(4 * i + 2) & bas(4 * i + 3);
		end loop;
		if ROM_CART'length > 0 then
			cart := load_hex(ROM_CART);
			for i in 0 to 2047 loop
				wait until rising_edge(clk);
				rl_we <= '1'; rl_waddr <= std_logic_vector(to_unsigned(4096 + i, 13));
				rl_wdata <= cart(4 * i) & cart(4 * i + 1) & cart(4 * i + 2) & cart(4 * i + 3);
			end loop;
			cart_en <= '1'; ide_present <= '1';
		end if;
		wait until rising_edge(clk);
		rl_we <= '0';
		wait for 1 us;
		reset <= '0';
		wait;
	end process;


	-- bus trace of the CPU (VHDL-2008 external names): one line per CPU cycle
	process
		file t : text open write_mode is "cp400_trace.txt";
		variable l : line;
		alias a  is <<signal .tb_cp400.dut.cpu_a : std_logic_vector(15 downto 0)>>;
		alias rw is <<signal .tb_cp400.dut.cpu_r_wn : std_logic>>;
		alias di is <<signal .tb_cp400.dut.cpu_d_i : std_logic_vector(7 downto 0)>>;
		alias dop is <<signal .tb_cp400.dut.cpu_d_o : std_logic_vector(7 downto 0)>>;
		alias en is <<signal .tb_cp400.dut.cpu_ena : std_logic>>;
		variable n : integer := 0;
	begin
		wait until reset = '0';
		wait for CPU_TRACE_FROM;
		loop
			wait until rising_edge(clk) and en = '1';
			if n < 8000 then
				write(l, to_hstring(a)); write(l, string'(" ")); write(l, rw); write(l, string'(" "));
				write(l, to_hstring(di)); write(l, string'(" ")); write(l, to_hstring(dop));
				writeline(t, l);
			end if;
			n := n + 1;
		end loop;
	end process;


	-- RAM write address check: the write must go to the CPU's address of that cycle
	process
		alias a  is <<signal .tb_cp400.dut.cpu_a : std_logic_vector(15 downto 0)>>;
		variable bad, good : integer := 0;
	begin
		wait until reset = '0';
		loop
			wait until rising_edge(clk);
			if ram_we = '1' then
				if ram_wa = a then good := good + 1;
				else
					bad := bad + 1;
					if bad < 15 then report "write at " & time'image(now) & " " & to_hstring(ram_wa) & " cpu " & to_hstring(a) & " good " & integer'image(good); end if;
				end if;
			end if;
		end loop;
	end process;


	-- per-clk trace of the memory control signals in a window (set by generics TRACE_FROM / TRACE_NS)
	process
		file t2 : text open write_mode is "cp400_sam.txt";
		variable l : line;
		alias ras is <<signal .tb_cp400.dut.ras_n : std_logic>>;
		alias cas is <<signal .tb_cp400.dut.cas_n : std_logic>>;
		alias ma  is <<signal .tb_cp400.dut.ma : std_logic_vector(7 downto 0)>>;
		alias sa  is <<signal .tb_cp400.dut.sam_a : std_logic_vector(15 downto 0)>>;
		alias wen is <<signal .tb_cp400.dut.sam_we_n : std_logic>>;
		alias e   is <<signal .tb_cp400.dut.clk_e : std_logic>>;
		alias q   is <<signal .tb_cp400.dut.clk_q : std_logic>>;
		alias ca  is <<signal .tb_cp400.dut.cpu_a : std_logic_vector(15 downto 0)>>;
		alias en  is <<signal .tb_cp400.dut.ena14 : std_logic>>;
	begin
		wait for TRACE_FROM;
		for i in 1 to 600 loop
			wait until rising_edge(clk);
			write(l, to_hstring(sa)); write(l, string'(" ")); write(l, to_hstring(ma)); write(l, string'(" ras=")); write(l, ras);
			write(l, string'(" cas=")); write(l, cas); write(l, string'(" we_n=")); write(l, wen);
			write(l, string'(" E=")); write(l, e); write(l, string'(" Q=")); write(l, q); write(l, string'(" en=")); write(l, en);
			write(l, string'(" cpu=")); write(l, to_hstring(ca)); write(l, string'(" ram_we=")); write(l, ram_we);
			writeline(t2, l);
		end loop;
		wait;
	end process;


	-- crash catcher: keep the last 400 CPU cycles; on the first write to $0000 after CPU_TRACE_FROM, write them out and stop
	process
		file t3 : text open write_mode is "cp400_crash.txt";
		variable l : line;
		alias a  is <<signal .tb_cp400.dut.cpu_a : std_logic_vector(15 downto 0)>>;
		alias rw is <<signal .tb_cp400.dut.cpu_r_wn : std_logic>>;
		alias di is <<signal .tb_cp400.dut.cpu_d_i : std_logic_vector(7 downto 0)>>;
		alias dop is <<signal .tb_cp400.dut.cpu_d_o : std_logic_vector(7 downto 0)>>;
		alias en is <<signal .tb_cp400.dut.cpu_ena : std_logic>>;
		type ring_t is array (0 to 399) of std_logic_vector(31 downto 0);
		variable ring : ring_t;
		variable wp : integer := 0;
	begin
		wait until reset = '0';
		wait for 1000 ms;
		loop
			wait until rising_edge(clk) and en = '1';
			ring(wp) := a & x"00" & di;
			wp := (wp + 1) mod 400;
			if a = x"0000" and rw = '0' then
				for i in 0 to 399 loop
					write(l, to_hstring(ring((wp + i) mod 400)(31 downto 16)));
					write(l, string'(" ")); write(l, to_hstring(ring((wp + i) mod 400)(7 downto 0)));
					writeline(t3, l);
				end loop;
				report "crash catcher fired";
				std.env.stop;
			end if;
		end loop;
	end process;


	-- keyboard: type KEYS (a string of D, I, R and the Enter key = "!") after the banner (CoCo matrix: bit = 8 * column + row)
	process
		function kbit(c : character) return integer is
		begin
			case c is
				when 'D' => return 8 * 4 + 0;
				when 'I' => return 8 * 1 + 1;
				when 'R' => return 8 * 2 + 2;
				when 'H' => return 8 * 0 + 1;
				when 'O' => return 8 * 7 + 1;
				when 'S' => return 8 * 3 + 2;
				when '!' => return 6;
				when others => return 0;
			end case;
		end function;
	begin
		wait until reset = '0';
		wait for KEY_AT;
		for k in TYPE_TEXT'range loop
			keys <= (others => '0');
			keys(kbit(TYPE_TEXT(k))) <= '1';
			wait for 120 ms;
			keys <= (others => '0');
			wait for 120 ms;
		end loop;
		wait;
	end process;


	-- every access of the CPU to $FF50-$FF5F (what the DOS does to the drive)
	process
		file t4 : text open write_mode is "cp400_ideacc.txt";
		variable l : line;
		variable n : integer := 0;
	begin
		wait until reset = '0';
		loop
			wait until rising_edge(clk) and ide_cs = '1' and ide_cyc_end = '1';
			if n < 4000 then
				write(l, time'image(now)); write(l, string'(" ")); write(l, to_hstring(ide_a));
				if ide_rw = '1' then write(l, string'(" R ")); write(l, to_hstring(ide_q));
				else write(l, string'(" W ")); write(l, to_hstring(ide_d)); end if;
				writeline(t4, l);
			end if;
			n := n + 1;
		end loop;
	end process;

	-- frame dump: the active picture is cap_ena and not cap_hb and not cap_vb; the rgb is one clk later
	process
		file f : text open write_mode is OUT_FILE;
		variable l : line;
		variable frame, row, col, even : integer := 0;
		variable en_d, hb_d, vb_d : std_logic := '1';
		variable vb_prev : std_logic := '1';
		variable hb_prev : std_logic := '1';
		variable line_idx : integer := 0;
		type img_t is array (0 to 191, 0 to 255) of integer;
		variable img : img_t;
		variable px : integer;
		function q(v : std_logic_vector(5 downto 0)) return integer is
		begin
			return to_integer(unsigned(v));
		end function;
	begin
		loop
			wait until rising_edge(clk);
			-- this clock's rgb belongs to last clock's enables
			if en_d = '1' and hb_d = '0' and vb_d = '0' then
				if (line_idx mod 2) = 0 and col < 256 and (line_idx / 2) < 192 then
					img(line_idx / 2, col) := q(cap_rgb);
				end if;
				col := col + 1;
			end if;
			-- line / frame counting on the (delayed) flags
			if cap_ena = '1' then
				if hb_prev = '0' and cap_hb = '1' then
					if vb_d = '0' then line_idx := line_idx + 1; end if;
					col := 0;
				end if;
				if vb_prev = '0' and cap_vb = '1' then
					-- end of the picture: dump it
					if frame mod 4 = 3 then
						write(l, string'("FRAME ") ); write(l, frame); writeline(f, l);
						for y in 0 to 191 loop
							for x in 0 to 255 loop
								write(l, string'(integer'image(img(y, x)) & " "));
							end loop;
							writeline(f, l);
						end loop;
					end if;
					frame := frame + 1;
					line_idx := 0;
					if frame >= FRAMES then
						report "done, frames: " & integer'image(frame);
						std.env.stop;
					end if;
				end if;
				hb_prev := cap_hb;
				vb_prev := cap_vb;
			end if;
			en_d := cap_ena; hb_d := cap_hb; vb_d := cap_vb;
		end loop;
	end process;
end architecture;
