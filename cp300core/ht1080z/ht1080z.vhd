--
-- HT 1080Z (TSR-80 clone) top level
--
--
-- Copyright (c) 2016-2017 Jozsef Laszlo (rbendr@gmail.com)
--
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- Please report bugs to the author, but before you do so, please
-- make sure that this is not a derivative work and that
-- you have the latest version of this file.
--


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;
-- synthesis translate_off
use std.textio.all;
use work.sim_trace_cfg.all;
-- synthesis translate_on

entity ht1080z is
    generic ( EXT_RAM : boolean := false;    -- true: Z80 RAM is outside (ext_ram_*), no SDRAM controller
              RUNTIME_ROM : boolean := false;   -- true: system ROM and character generator are RAMs loaded through rl_*
              EXT_CPU : boolean := false );     -- true: no Z80 inside, the xcpu_* ports reach one outside (shared by several machines)
    Port ( clk42m : in  STD_LOGIC;
        pllLocked : in  STD_LOGIC;
            reset : in  STD_LOGIC;
              led : out STD_LOGIC;
             ntsc : in  STD_LOGIC;
        ext_keys : in  std_logic_vector(63 downto 0);   -- original keyboard matrix, 8 * row + column
            turbo : in  STD_LOGIC;
          cass_in : in  STD_LOGIC;
         cass_out : out std_logic_vector(1 downto 0);
        -- a second user of the WD1793 (the MSX1's disk interface, rtl bvf_msx1.v): while xf_en = 1 its bus replaces the CP-300's
        xf_en : in std_logic := '0';
        xf_rst : in std_logic := '0';
        xf_ce : in std_logic := '0';
        xf_sel : in std_logic := '0';
        xf_rd : in std_logic := '0';
        xf_wr : in std_logic := '0';
        xf_addr : in std_logic_vector(1 downto 0) := "00";
        xf_din : in std_logic_vector(7 downto 0) := (others => '0');
        xf_dout : out std_logic_vector(7 downto 0);
        xf_drq : out std_logic;
        xf_intrq : out std_logic;
        xf_drive : in std_logic_vector(1 downto 0) := "00";
        xf_side : in std_logic := '0';
        xf_ready : in std_logic := '0';
        xf_wp : in std_logic := '0';
        xf_sec512 : in std_logic := '1';

         -- floppy controller: images are served by the IO controller
        fdc_svc_rd : out std_logic;
        fdc_svc_wr : out std_logic;
        fdc_svc_ra : out std_logic;
     fdc_svc_track : out std_logic_vector(7 downto 0);
    fdc_svc_trkreg : out std_logic_vector(7 downto 0);
    fdc_svc_sector : out std_logic_vector(7 downto 0);
       fdc_svc_dam : out std_logic;
       fdc_svc_ack : in  std_logic;
     fdc_res_found : in  std_logic;
       fdc_res_crc : in  std_logic;
       fdc_res_dam : in  std_logic;
     fdc_buff_addr : in  std_logic_vector(8 downto 0);
     fdc_buff_dout : in  std_logic_vector(7 downto 0);
      fdc_buff_din : out std_logic_vector(7 downto 0);
       fdc_buff_wr : in  std_logic;
         fdc_drive : out std_logic_vector(1 downto 0);
          fdc_side : out std_logic;
         hd_svc : out std_logic;                          -- the pending sector request is the hard disk's
        hd_flags : in  std_logic_vector(3 downto 0);     -- b1:0 image mounted in hard disk 0/1, b3:2 write protected
        drv_ready : in  std_logic_vector(3 downto 0);
            drv_wp : in  std_logic_vector(3 downto 0);

           ps2clk : in  STD_LOGIC;
           ps2dat : in  STD_LOGIC;

           ht_rgb : out std_logic_vector(17 downto 0);
         -- raw picture (see videoctrl): 1 bit per pixel + the three colours, for frame-buffer back ends
       vid_screen : out std_logic;
          vid_ink : out std_logic;
         vid_pxen : out std_logic;
      vid_ink_rgb : out std_logic_vector(17 downto 0);
    vid_paper_rgb : out std_logic_vector(17 downto 0);
   vid_border_rgb : out std_logic_vector(17 downto 0);
               hs : out STD_LOGIC;
               vs : out STD_LOGIC;
               hb : out STD_LOGIC;
               vb : out STD_LOGIC;
         audiomix : out std_logic_vector(8 downto 0); 

            dn_go : in  std_logic;
            dn_wr : in  std_logic;
          dn_addr : in  std_logic_vector(24 downto 0);
          dn_data : in  std_logic_vector(7 downto 0);
           dn_idx : in  std_logic_vector(4 downto 0);

         exp_addr : out std_logic_vector(15 downto 0);
           exp_in : out std_logic;
          exp_out : out std_logic;
         exp_dout : out std_logic_vector(7 downto 0);
          exp_din : in  std_logic_vector(7 downto 0);
           exp_oe : in  std_logic;

         -- external RAM (EXT_RAM = true): the owner of the RAM raises ext_ram_wait
         -- until the access of the current Z80 cycle is done
      ext_ram_addr : out std_logic_vector(15 downto 0);
        ext_ram_rd : out std_logic;
        ext_ram_wr : out std_logic;
       ext_ram_din : out std_logic_vector(7 downto 0);
      ext_ram_dout : in  std_logic_vector(7 downto 0) := x"ff";
      ext_ram_wait : in  std_logic := '0';

		 -- SDRAM
		  SDRAM_nCS : out std_logic;                     -- Chip Select
		   SDRAM_DQ : inout std_logic_vector(15 downto 0); -- SDRAM Data bus 16 Bits
		    SDRAM_A : out std_logic_vector(12 downto 0);  -- SDRAM Address bus 13 Bits
		 SDRAM_DQMH : out std_logic; -- SDRAM High Data Mask
		 SDRAM_DQML : out std_logic; -- SDRAM Low-byte Data Mask
		  SDRAM_nWE : out std_logic;  -- SDRAM Write Enable
		 SDRAM_nCAS : out std_logic; -- SDRAM Column Address Strobe
		 SDRAM_nRAS : out std_logic; -- SDRAM Row Address Strobe
		   SDRAM_BA : out std_logic_vector(1 downto 0); -- SDRAM Bank Address
		  SDRAM_CKE : out std_logic;  -- SDRAM Clock Enable
  			  			  
         -- runtime ROM loader (RUNTIME_ROM): 32-bit words, see cp300_rom
           rl_clk : in  std_logic := '0';
            rl_we : in  std_logic := '0';
         rl_waddr : in  std_logic_vector(12 downto 0) := (others => '0');
         rl_wdata : in  std_logic_vector(31 downto 0) := (others => '0');

         -- the Z80 outside (EXT_CPU): its controls from this machine, its bus to this machine
         xcpu_reset_n : out std_logic;
         xcpu_cen     : out std_logic;
         xcpu_wait_n  : out std_logic;
         xcpu_int_n   : out std_logic;
         xcpu_nmi_n   : out std_logic;
         xcpu_di      : out std_logic_vector(7 downto 0);
         xcpu_m1_n    : in  std_logic := '1';
         xcpu_mreq_n  : in  std_logic := '1';
         xcpu_iorq_n  : in  std_logic := '1';
         xcpu_rd_n    : in  std_logic := '1';
         xcpu_wr_n    : in  std_logic := '1';
         xcpu_a       : in  std_logic_vector(15 downto 0) := (others => '0');
         xcpu_do      : in  std_logic_vector(7 downto 0) := (others => '0')
    ); 
end ht1080z;

architecture Behavioral of ht1080z is

component sdram is
      port( sd_data : inout std_logic_vector(15 downto 0);
            sd_addr : out std_logic_vector(12 downto 0);
             sd_dqm : out std_logic_vector(1 downto 0);
              sd_ba : out std_logic_vector(1 downto 0);
              sd_cs : out std_logic;
              sd_we : out std_logic;
             sd_ras : out std_logic;
             sd_cas : out std_logic;
               init : in std_logic;
                clk : in std_logic;
                din : in std_logic_vector(7 downto 0);
               dout : out std_logic_vector(7 downto 0);
               addr : in std_logic_vector(24 downto 0);
                 oe : in std_logic;
                 we : in std_logic
      );
end component;

signal sdram_dqm  : std_logic_vector(1 downto 0);
signal ram_addr : std_logic_vector(24 downto 0);
signal  ram_din : STD_LOGIC_VECTOR(7 downto 0);
signal ram_dout : STD_LOGIC_VECTOR(7 downto 0);
signal ram_dout_sdram : STD_LOGIC_VECTOR(7 downto 0);
signal ram_we: std_logic;
signal ram_oe: std_logic; 

signal   dn_wr_r : std_logic;
signal dn_wr_new : std_logic;
signal dn_addr_r : std_logic_vector(24 downto 0);
signal dn_data_r : std_logic_vector(7 downto 0);

signal res_cnt : std_logic_vector(10 downto 0) := (others => '1');   -- reset lasts 2047 clocks: the video RAM is cleared meanwhile
signal autores : std_logic; 

signal cpua     : std_logic_vector(15 downto 0); 
signal cpudo    : std_logic_vector(7 downto 0);
signal cpudi    : std_logic_vector(7 downto 0);
signal cpuwr,cpurd,cpumreq,cpuiorq,cpunmi,cpuint,cpum1,cpuClkEn,clkref : std_logic;

signal rgbi : std_logic_vector(3 downto 0);
signal ink_c, paper_c, border_c : std_logic_vector(3 downto 0);
  function pal(c : std_logic_vector(3 downto 0)) return std_logic_vector is
  begin
    case c is
      when "0000" => return "000000000000000000";
      when "0001" => return "000000000000100000";
      when "0010" => return "000000100000000000";
      when "0011" => return "000000100000100000";
      when "0100" => return "100000000000000000";
      when "0101" => return "100000000000100000";
      when "0110" => return "110000011000000000";
      when "0111" => return "100000100000100000";
      when "1000" => return "110000110000110000";
      when "1001" => return "000000000000111100";
      when "1010" => return "000000111100000000";
      when "1011" => return "000000111100111100";
      when "1100" => return "111110000000000000";
      when "1101" => return "111100000000111100";
      when "1110" => return "111110111110000000";
      when others => return "111110111110111110";
    end case;
  end function;

signal romdo,vramdo,ramdo,ramHdo,kbdout : std_logic_vector(7 downto 0);
signal vramcs : std_logic;

signal page,swres : std_logic;

signal romrd,ramrd,ramwr,vramsel,kbdsel : std_logic;
signal ior,iow,memr,memw : std_logic;
signal vdata : std_logic_vector(7 downto 0);

signal clk42div : std_logic_vector(4 downto 0) := (others => '0');

signal dacout : std_logic;
signal oaudio,snddo : std_logic_vector(7 downto 0) := (others => '0'); 

signal p_hs,p_vs,vgahs,vgavs : std_logic; 
signal pclk : std_logic; 


signal tapebits : std_logic_vector(2 downto 0); 
signal  speaker : std_logic_vector(7 downto 0); 
signal vga : std_logic := '0';
signal oddline : std_logic;

signal inkpulse, paperpulse, borderpulse : std_logic;

-- Model III I/O
signal ec      : std_logic_vector(7 downto 0) := (others => '0'); -- port EC write latch
signal intmask : std_logic_vector(7 downto 0) := (others => '0'); -- port E0 write
signal intstat : std_logic_vector(7 downto 0) := (others => '0'); -- active-high latches; bit 2 = 30 Hz RTC
signal nmimask : std_logic_vector(7 downto 0) := (others => '0'); -- port E4 write
signal fdc_intrq, fdc_motoff : std_logic := '0'; -- WD1793 INTRQ, motor timeout (not modelled)
signal rtc_cnt : integer range 0 to 1399999 := 0; -- 42 MHz / 30 Hz
signal e0sel, e4sel, ecsel, ffsel : std_logic;

-- floppy controller (ports F0-F3) and drive select latch (F4)
signal f4      : std_logic_vector(7 downto 0) := (others => '0');
signal fdcsel, f3sel : std_logic;
signal fdc_dout : std_logic_vector(7 downto 0);
signal fdc_drq, fdc_busy : std_logic;
signal fdc_rdy, fdc_wp_i : std_logic;
signal fdc_drv_x : std_logic_vector(1 downto 0);
signal fdc_addr_x : std_logic_vector(1 downto 0);
signal fdc_din_x : std_logic_vector(7 downto 0);
signal fdc_side_x, fdc_rdy_x, fdc_wp_x, fdc_ce : std_logic;
signal fdc_drv : std_logic_vector(1 downto 0);
signal fdc_drv_on : std_logic;
signal fdc_reset : std_logic;
signal fdc_i_rd, fdc_i_wr, fdc_i_dam, fdc_i_ack, fdc_i_bwr : std_logic;
signal fdc_i_track, fdc_i_trkreg, fdc_i_sector, fdc_i_bdin : std_logic_vector(7 downto 0);
signal hdsel, hd_dev, hd_rd, hd_wr, hd_busy, hd_ack : std_logic;
signal hd_dout, hd_bdin : std_logic_vector(7 downto 0);
signal hd_cyl : std_logic_vector(9 downto 0);
signal hd_head : std_logic_vector(2 downto 0);
signal hd_sector : std_logic_vector(7 downto 0);
signal hd_drive : std_logic_vector(1 downto 0);
signal wait_cnt : std_logic_vector(21 downto 0) := (others => '0');
signal cpuwait : std_logic;
signal cpuwait_c : std_logic;   -- WAIT_n before the register stage used with EXT_RAM
signal wait_r : std_logic := '1';
signal waiting : std_logic;

begin

  led <= not dn_go;--swres;
  
  process(clk42m)
  begin
    if rising_edge(clk42m) then
	    clk42div <= clk42div + 1;
		 -- 42 MHz/21 = 2.0 MHz (CP-300)
		 if clk42div = 20 then clk42div <= (others => '0'); end if;
	 end if;
  end process;
  
  ior <= cpurd or cpuiorq or (not cpum1);
  iow <= cpuwr or cpuiorq;
  memr <= cpurd or cpumreq;
  memw <= cpuwr or cpumreq;
  
  -- CP-300 decoder CI-44: ROM 0000-37FF, keyboard 3800, video RAM 3C00
  romrd <= '1' when memr='0' and cpua<x"3800" else '0';
  ramrd <= '1' when cpua(15 downto 14)/="00" and memr='0' else '0';
  ramwr <= '1' when cpua(15 downto 14)/="00" and memw='0' else '0';
  vramsel <= '1' when cpua(15 downto 10)="001111" and cpumreq='0' else '0';
  kbdsel  <= '1' when cpua(15 downto 10)="001110" and memr='0' else '0';
  e0sel <= '1' when cpua(7 downto 0)=x"e0" else '0';
  e4sel <= '1' when cpua(7 downto 0)=x"e4" else '0';
  ecsel <= '1' when cpua(7 downto 0)=x"ec" else '0';
  ffsel <= '1' when cpua(7 downto 0)=x"ff" else '0';
  fdcsel <= '1' when cpua(7 downto 2)="111100" else '0';
  f3sel  <= '1' when cpua(7 downto 0)=x"f3" else '0';

  -- F4 bits 0-3 select a drive (lowest set bit wins), bit 4 side, bit 6 wait enable
  fdc_drv_on <= f4(0) or f4(1) or f4(2) or f4(3);
  fdc_drv    <= "00" when f4(0)='1' else "01" when f4(1)='1' else "10" when f4(2)='1' else "11";
  fdc_rdy    <= fdc_drv_on and drv_ready(conv_integer(fdc_drv));
  fdc_wp_i   <= drv_wp(conv_integer(fdc_drv));
  fdc_drv_x  <= xf_drive when xf_en = '1' else fdc_drv;
  fdc_side_x <= xf_side when xf_en = '1' else f4(4);
  fdc_rdy_x  <= xf_ready when xf_en = '1' else fdc_rdy;
  fdc_wp_x   <= xf_wp when xf_en = '1' else fdc_wp_i;
  fdc_drive  <= hd_drive when hd_busy = '1' else fdc_drv_x;
  fdc_side   <= fdc_side_x;
  fdc_reset  <= xf_rst when xf_en = '1' else '1' when autores='0' or dn_go='1' else '0';
  fdc_ce     <= xf_ce when xf_en = '1' else cpuClkEn;
  fdc_addr_x <= xf_addr when xf_en = '1' else cpua(1 downto 0);
  fdc_din_x  <= xf_din when xf_en = '1' else cpudo;
  xf_dout <= fdc_dout; xf_drq <= fdc_drq; xf_intrq <= fdc_intrq;

  fdc : entity work.wd1793
    port map (
      clk_sys => clk42m, ce => fdc_ce, reset => fdc_reset,
      io_en => fdcsel or xf_sel, rd => (not ior) or xf_rd, wr => (not iow) or xf_wr, addr => fdc_addr_x,
      din => fdc_din_x, dout => fdc_dout, drq => fdc_drq, intrq => fdc_intrq, busy => fdc_busy,
      drive => fdc_drv_x, side => fdc_side_x, ready => fdc_rdy_x, wp => fdc_wp_x, sec512 => xf_sec512 and xf_en,
      svc_rd => fdc_i_rd, svc_wr => fdc_i_wr, svc_ra => fdc_svc_ra,
      svc_track => fdc_i_track, svc_trkreg => fdc_i_trkreg, svc_sector => fdc_i_sector,
      svc_dam => fdc_i_dam, svc_ack => fdc_i_ack,
      res_found => fdc_res_found, res_crc => fdc_res_crc, res_dam => fdc_res_dam,
      svc_buff_addr => fdc_buff_addr, svc_buff_dout => fdc_buff_dout, svc_buff_din => fdc_i_bdin,
      svc_buff_wr => fdc_i_bwr
    );

  -- FreeHD hard disk interface: ports C0-CF, answers only while an image is mounted (else FF, as
  -- an empty expansion bus). It shares the IO controller's sector service with the floppy
  -- controller: while hd_busy is up the request, its address and the buffer are the hard disk's.
  hdsel  <= '1' when cpua(7 downto 4)="1100" else '0';
  hd_dev <= hd_flags(0) or hd_flags(1);
  hdc : entity work.wd1010
    port map (
      clk_sys => clk42m, ce => cpuClkEn, reset => fdc_reset,
      io_en => hdsel, rd => not ior, wr => not iow, addr => cpua(3 downto 0),
      din => cpudo, dout => hd_dout,
      hd_ready => hd_flags(1 downto 0), hd_wp => hd_flags(3 downto 2),
      svc_rd => hd_rd, svc_wr => hd_wr, svc_busy => hd_busy,
      svc_cyl => hd_cyl, svc_head => hd_head, svc_sector => hd_sector, svc_drive => hd_drive,
      svc_ack => hd_ack, res_found => fdc_res_found,
      svc_buff_addr => fdc_buff_addr, svc_buff_dout => fdc_buff_dout, svc_buff_din => hd_bdin,
      svc_buff_wr => fdc_buff_wr
    );
  hd_ack         <= fdc_svc_ack and hd_busy;
  fdc_i_ack      <= fdc_svc_ack and not hd_busy;
  fdc_i_bwr      <= fdc_buff_wr and not hd_busy;
  fdc_svc_rd     <= fdc_i_rd or hd_rd;
  fdc_svc_wr     <= fdc_i_wr or hd_wr;
  fdc_svc_track  <= hd_cyl(7 downto 0) when hd_busy = '1' else fdc_i_track;
  fdc_svc_trkreg <= "000" & hd_head & hd_cyl(9 downto 8) when hd_busy = '1' else fdc_i_trkreg;
  fdc_svc_sector <= hd_sector when hd_busy = '1' else fdc_i_sector;
  fdc_svc_dam    <= '0' when hd_busy = '1' else fdc_i_dam;
  fdc_buff_din   <= hd_bdin when hd_busy = '1' else fdc_i_bdin;
  hd_svc         <= hd_busy;

  -- wait states: a data register access (F3) holds the CPU until DRQ or INTRQ when F4 bit 6 is set.
  -- A 100 ms timeout releases a stuck CPU.
  waiting <= '1' when f4(6)='1' and f3sel='1' and (ior='0' or iow='0') and fdc_drq='0' and fdc_intrq='0' else '0';
  cpuwait_c <= '0' when (waiting='1' and wait_cnt(21)='0') or ext_ram_wait='1' else '1';

  -- EXT_RAM (slower FPGAs): WAIT_n comes from a register that only changes late in the CPU's
  -- enable period (clk42div 6 and 16, the Z80 samples it on the enables at 0 and, in turbo, 10).
  -- Its long paths into the T80 then have several clocks to settle.
  process(clk42m)
  begin
    if rising_edge(clk42m) then
      if clk42div = 6 or clk42div = 16 then wait_r <= cpuwait_c; end if;
    end if;
  end process;
  cpuwait <= wait_r when EXT_RAM else cpuwait_c;

  -- IM 1 timer interrupt and NMI: masked latches, active low
  cpuint <= '0' when (intstat and intmask) /= x"00" else '1';
  cpunmi <= '0' when (fdc_intrq = '1' and nmimask(7) = '1') or (fdc_motoff = '1' and nmimask(6) = '1') else '1';
  cass_out <= tapebits(1 downto 0);

  exp_addr <= cpua;
  exp_out <= not iow;
  exp_in <= not ior;
  exp_dout <= cpudo;

  xcpu_reset_n <= autores;
  xcpu_cen     <= cpuClkEn and not dn_go;
  xcpu_wait_n  <= cpuwait;
  xcpu_int_n   <= cpuint;
  xcpu_nmi_n   <= cpunmi;
  xcpu_di      <= cpudi;

  g_xcpu : if EXT_CPU generate
    cpum1   <= xcpu_m1_n;
    cpumreq <= xcpu_mreq_n;
    cpuiorq <= xcpu_iorq_n;
    cpurd   <= xcpu_rd_n;
    cpuwr   <= xcpu_wr_n;
    cpua    <= xcpu_a;
    cpudo   <= xcpu_do;
  end generate;

  g_cpu : if not EXT_CPU generate
  cpu : entity work.T80s
   port map (  
	   RESET_n => autores, --swres,
		CLK     => clk42m, 
		CEN     => cpuClkEn and not dn_go, -- 2.0 MHz
		WAIT_n  => cpuwait,
		INT_n   => cpuint,
		NMI_n   => cpunmi,
		BUSRQ_n => '1',
		M1_n    => cpum1,
		MREQ_n  => cpumreq,
		IORQ_n  => cpuiorq,
		RD_n    => cpurd,
		WR_n    => cpuwr,
		RFSH_n  => open,
		HALT_n  => open,
		BUSAK_n => open,
		A       => cpua, 
		DI      => cpudi,
		DO      => cpudo
  );
  end generate;

  cpudi <= --romdo when romrd='1' else
	        --ramdo when ramrd='1' else
           exp_din when exp_oe = '1' else
			  romdo when romrd='1' else
			  ram_dout when ramrd='1' else
			  vramdo when vramsel='1' else
			  kbdout when kbdsel='1' else
			  x"30" when ior='0' and cpua(7 downto 0)=x"fd" else -- printer io read
			  -- WD1793 at F0-F3; F4-F7 read FF. Without a disk the status reads NOT READY
			  -- and the ROM falls through to "Cass?".
			  -- An empty drive 0 answers like a missing controller (status 00, no Track 0): the ROM then
			  -- goes to "Cass?" instead of printing "Diskette?" forever. Mount a disk and use the
			  -- menu's reset to boot it.
			  x"00" when ior='0' and cpua(7 downto 0)=x"f0" and fdc_drv="00" and fdc_rdy='0' else
			  fdc_dout when ior='0' and fdcsel='1' else
			  hd_dout when ior='0' and hdsel='1' and hd_dev='1' else
				  -- Model III: E0 interrupt status (active low), E4 NMI status (bit 7 INTRQ,
				  -- bit 6 motor timeout, active low), FF bit 7 cassette input
				  not (intstat and intmask) when ior='0' and e0sel='1' else
				  not (fdc_intrq & fdc_motoff & "000000") when ior='0' and e4sel='1' else
				  cass_in & "1111111" when ior='0' and ffsel='1' else
				  x"ff";

  -- the CP-300 character generator has its own glyphs for 00-1F
  vdata <= cpudo;

  rom : entity work.cp300_rom
    generic map (RUNTIME_ROM => RUNTIME_ROM)
    port map (
      clk  => clk42m,
      a    => cpua(13 downto 0),
      dout => romdo,
      rl_clk => rl_clk, rl_we => rl_we, rl_waddr => rl_waddr, rl_wdata => rl_wdata
    );

  -- video ram at 0x3C00
  video : entity work.videoctrl 
    generic map (RUNTIME_ROM => RUNTIME_ROM)
    port map (   
	  reset => autores, --swres and pllLocked,
	  clk42 => clk42m,
			a => cpua(13 downto 0),
		 din => vdata,--cpudo,
		dout => vramdo,
		mreq => cpumreq,
		iorq => cpuiorq,
		  wr => cpuwr,
		  cs => not vramsel,
		hz60 => ntsc,
		vcut => ec(2),
			kana => ec(3),
		vvga => '0',
		page => page,
		rgbi => rgbi, 
	   pclk => pclk,
		inkp => inkpulse,
	 paperp => paperpulse,
	borderp => borderpulse,
	oddline => oddline,
	pix_screen => vid_screen, pix_ink => vid_ink, pix_en => vid_pxen,
	ink_c => ink_c, paper_c => paper_c, border_c => border_c,
	  hsync => hs,
	  vsync => vs,
	  hblank=> hb,
	  vblank=> vb,
	  rl_clk => rl_clk, rl_we => rl_we, rl_waddr => rl_waddr, rl_wdata => rl_wdata
   );  

  kbd : entity work.ps2kbd 
    port  map ( 
	   RESET => not pllLocked,
 	   KBCLK => ps2clk,
	   KBDAT => ps2dat,
		SWRES => swres,
	     CLK => clk42m,
		    A => cpua(7 downto 0),
			 EXT => ext_keys,
		 DOUT => kbdout,
		 PAGE => page,
		 VCUT => open,
		 INKP => inkpulse,
	  PAPERP => paperpulse,
	 BORDERP => borderpulse
		  );
	
  with tapebits select speaker <=
   "00100000" when "001",
	"00010000" when "000"|"011",
   "00000000" when others;
 
  audiomix <= '0' & speaker; 
 	 
	-- fix palette for now
	--with rgbi select rgb <=
	ht_rgb <= pal(rgbi);
	vid_ink_rgb <= pal(ink_c); vid_paper_rgb <= pal(paper_c); vid_border_rgb <= pal(border_c);
  sdram_gen : if not EXT_RAM generate
  sdram_inst : sdram
    port map( sd_data => SDRAM_DQ,
              sd_addr => SDRAM_A,
               sd_dqm => sdram_dqm,
                sd_cs => SDRAM_nCS,
                sd_ba => SDRAM_BA,
                sd_we => SDRAM_nWE,
               sd_ras => SDRAM_nRAS,
               sd_cas => SDRAM_nCAS,
                  clk => clk42m,
                 init => not pllLocked,
                  din => ram_din,
                 addr => ram_addr,
                   we => ram_we,
                   oe => ram_oe,
                 dout => ram_dout_sdram
    ); 	
  end generate;
  sdram_off : if EXT_RAM generate
    SDRAM_nCS <= '1'; SDRAM_A <= (others => '0'); SDRAM_nWE <= '1'; SDRAM_nCAS <= '1';
    SDRAM_nRAS <= '1'; SDRAM_BA <= "00"; SDRAM_DQ <= (others => 'Z'); sdram_dqm <= "11";
    ram_dout_sdram <= x"ff";
  end generate;
  ext_ram_addr <= cpua;
  ext_ram_rd   <= ramrd when EXT_RAM else '0';
  ext_ram_wr   <= ramwr when EXT_RAM else '0';
  ext_ram_din  <= cpudo;
  ram_dout     <= ext_ram_dout when EXT_RAM else ram_dout_sdram;
  --ram_addr <= "000000000" & cpua when dn_go='0' else dn_addr_r; 
  ram_din <= cpudo when dn_go='0' else dn_data_r;
  ram_we <= ((not memw) and (cpua(15) or cpua(14))) when dn_go='0' else dn_wr_r; 
  --ram_oe <= not memr when dn_go='0' else '0';
  
  ram_addr <= "000000000" & cpua when dn_go='0' else dn_addr_r; 
  ram_oe <= not memr when dn_go='0' else '0';
	 
  -- sdram interface
  SDRAM_CKE <= '1';
  SDRAM_DQMH <= sdram_dqm(1);
  SDRAM_DQML <= sdram_dqm(0); 	 

  process(clk42m)
  -- sync wr from data io to sdram clkref
  begin
    if rising_edge(clk42m) then
	   if dn_wr='1' then
		  dn_wr_new <= '1';
		  dn_data_r <= dn_data;
			if dn_idx = x"00" then
				dn_addr_r <= dn_addr;
			else
				dn_addr_r <= dn_addr + x"10000";
			end if;
		end if;
		if clkref = '1' then
			if dn_wr_new = '1' then
				dn_wr_r <= '1';
				dn_wr_new <= '0';
			else
				dn_wr_r <= '0';
			end if;
		end if;
	 end if;
  end process; 
  
 process (clk42m, pllLocked)
 begin
   if pllLocked = '0' then
		  res_cnt <= (others => '0');
   elsif rising_edge(clk42m) then
		if reset = '1' then
		  res_cnt <= (others => '0');
		else
		  if (res_cnt/=(res_cnt'range => '1')) then
			 res_cnt <= res_cnt+1;
		  end if;
		end if;
   end if;
 end process;
 
 cpuClkEn <= '1' when clk42div = 0 or (turbo = '1' and clk42div = 10) else '0'; -- 42/21 = 2.0 MHz
 clkref <= '1' when clk42div = 0 or clk42div = 10 else '0'; -- ~4 MHz
 autores <= '1' when res_cnt=(res_cnt'range => '1') else '0';   


 -- Model III I/O ports
 process (clk42m)
 begin
   if rising_edge(clk42m) then
     if dn_go='1' or autores='0' then
       tapebits <= "000";
       f4 <= (others => '0');
       ec <= (others => '0');
       intmask <= (others => '0');
       intstat <= (others => '0');
       nmimask <= (others => '0');
       rtc_cnt <= 0;
     else
       if waiting = '1' then
         if wait_cnt(21) = '0' then wait_cnt <= wait_cnt + 1; end if;
       else
         wait_cnt <= (others => '0');
       end if;
       -- 30 Hz real-time clock
       if rtc_cnt = 1399999 then
         rtc_cnt <= 0;
         intstat(2) <= '1';
       else
         rtc_cnt <= rtc_cnt + 1;
       end if;
       if cpuClkEn = '1' then
         if iow='0' then
           if ffsel='1' then tapebits <= cpudo(2 downto 0); end if;
           if e0sel='1' then intmask <= cpudo; end if;
           if e4sel='1' then nmimask <= cpudo; end if;
           if ecsel='1' then ec <= cpudo; end if;
           if cpua(7 downto 0)=x"f4" then f4 <= cpudo; end if;
         end if;
         -- reading EC acknowledges the RTC interrupt
         if ior='0' and ecsel='1' then intstat(2) <= '0'; end if;
       end if;
     end if;
   end if;
 end process;

-- synthesis translate_off
-- Simulation only: log opcode fetches and memory writes to trace.txt
-- between TRACE_FROM and TRACE_TO (sim/run.sh generates sim_trace_cfg).
process(clk42m)
  file f : text;
  variable l : line;
  variable opened : boolean := false;
  variable fetch, wrcyc, fetch_old, wrcyc_old : boolean := false;
  variable op : std_logic_vector(7 downto 0);
  variable pc : std_logic_vector(15 downto 0);
begin
  if rising_edge(clk42m) and now >= TRACE_FROM and now < TRACE_TO then
    if not opened then
      file_open(f, "trace.txt", write_mode);
      opened := true;
    end if;
    fetch := cpum1 = '0' and cpumreq = '0' and cpurd = '0';
    wrcyc := cpumreq = '0' and cpuwr = '0';
    if fetch then
      pc := cpua; op := cpudi;
    end if;
    if fetch_old and not fetch then
      write(l, string'("PC ")); hwrite(l, pc); write(l, string'(" ")); hwrite(l, op);
      writeline(f, l);
    end if;
    if wrcyc and not wrcyc_old then
      write(l, string'("WR ")); hwrite(l, cpua); write(l, string'(" ")); hwrite(l, cpudo);
      writeline(f, l);
    end if;
    fetch_old := fetch;
    wrcyc_old := wrcyc;
  end if;
end process;
-- synthesis translate_on

end Behavioral;
