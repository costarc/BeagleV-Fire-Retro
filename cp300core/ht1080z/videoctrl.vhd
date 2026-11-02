--
-- HT 1080Z (TSR-80 clone) video controller PAL/VGA capable
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

use work.cp300_roms_pkg.all;

-- synthesis translate_off
use std.textio.all;
-- synthesis translate_on

entity videoctrl is
	Generic (
		-- CP-300: 64 x 8-dot cells = 512 active pixels in the 672-clock line
		H_START : integer := 42+76+17;
		V_START : integer := 2+28+((266-192)/2)+4;
		-- character generator in a RAM loaded through rl_* (see cp300_rom), not from cp300_roms_pkg
		RUNTIME_ROM : boolean := false
	 );
    Port (   
	        reset : in  STD_LOGIC;
		     clk42 : in  STD_LOGIC;
			   --clk7 : in  STD_LOGIC;
               a : in  STD_LOGIC_VECTOR (13 downto 0);
             din : in  STD_LOGIC_VECTOR (7 downto 0);
            dout : out STD_LOGIC_VECTOR (7 downto 0);
            mreq : in  STD_LOGIC;
            iorq : in  STD_LOGIC;
              wr : in  STD_LOGIC;
				  cs : in  STD_LOGIC;
				hz60 : in  STD_LOGIC;
				vcut : in  STD_LOGIC;
				kana : in  STD_LOGIC;
				vvga : in  STD_LOGIC;
				page : in  STD_LOGIC;
				inkp : in  STD_LOGIC;
			 paperp : in  STD_LOGIC;
			borderp : in  STD_LOGIC;
			oddline : out STD_LOGIC;
			-- raw picture for frame-buffer back ends: pix_ink is the pixel (1 = ink) while pix_screen is high,
			-- sampled on pix_en; ink_c/paper_c/border_c are the current colours (rgbi)
			pix_screen : out STD_LOGIC;
			pix_ink : out STD_LOGIC;
			pix_en : out STD_LOGIC;
			ink_c : out STD_LOGIC_VECTOR (3 downto 0);
			paper_c : out STD_LOGIC_VECTOR (3 downto 0);
			border_c : out STD_LOGIC_VECTOR (3 downto 0);
            rgbi : out STD_LOGIC_VECTOR (3 downto 0);	
				pclk : out STD_LOGIC;
           hsync : out STD_LOGIC;
           vsync : out STD_LOGIC;
          hblank : out STD_LOGIC;
          vblank : out STD_LOGIC;
          rl_clk   : in  STD_LOGIC := '0';
          rl_we    : in  STD_LOGIC := '0';
          rl_waddr : in  STD_LOGIC_VECTOR (12 downto 0) := (others => '0');
          rl_wdata : in  STD_LOGIC_VECTOR (31 downto 0) := (others => '0')
    );
end videoctrl;

architecture Behavioral of videoctrl is

type videomem is array(0 to 1023) of std_logic_vector(7 downto 0);

signal clrcnt : unsigned(9 downto 0) := (others => '0');
signal vwe : std_logic;
signal vwaddr : std_logic_vector(9 downto 0);
signal vwdata : std_logic_vector(7 downto 0);
signal vidmem : videomem:=(
others => x"00"
);

-- 0  1    2
-- 21 10.5 5.25
signal clkdiv : std_logic_vector(2 downto 0) := (others => '0');
alias   clk21 : std_logic is clkdiv(0);
alias clk10_5 : std_logic is clkdiv(1);
alias clk5_25 : std_logic is clkdiv(2);

signal clk21_en   : std_logic;
signal clk10_5_en : std_logic;
signal clk5_25_en : std_logic;

signal hctr : std_logic_vector(9 downto 0) := (others => '0');
signal vctr : std_logic_vector(8 downto 0) := (others => '0');
signal vpos : std_logic_vector(3 downto 0) := (others => '0'); -- line pos in a chr 0..11
signal hpos : std_logic_vector(2 downto 0) := (others => '0'); -- pixel pos in a chr 0..7
signal hstart : std_logic_vector(9 downto 0);
signal vstart : std_logic_vector(8 downto 0);
signal vend : std_logic_vector(8 downto 0);

signal pxclk : std_logic;
signal pxclk_en : std_logic;
signal xpxclk : std_logic;
signal xpxclk_en : std_logic;

signal hact,vact : std_logic;

signal border : std_logic_vector(3 downto 0) := "0010";
signal  paper : std_logic_vector(3 downto 0) := "0000";
signal    ink : std_logic_vector(3 downto 0) := "1000";
signal  pixel : std_logic_vector(3 downto 0);

signal screen : std_logic;
signal hblank_n, vblank_n : std_logic;
signal blank : std_logic;

signal vaVert : std_logic_vector(3 downto 0) := (others => '0'); -- vertical line
signal vaHoriz : std_logic_vector(5 downto 0) := (others => '0'); -- horizontal columnt pos

signal chraddr : std_logic_vector(10 downto 0); -- CI-59 address: code & scan line
signal chrCode : std_logic_vector(7 downto 0);
signal chrRom  : std_logic_vector(7 downto 0);
signal chrBlk  : std_logic_vector(7 downto 0);
signal chrSel  : std_logic_vector(1 downto 0);
signal chrGrap : std_logic_vector(7 downto 0);
signal shiftReg : std_logic_vector(7 downto 0);

signal xpxsel : std_logic_vector(1 downto 0);
signal     v1 : std_logic := '0';

signal rinkp,rpaperp,rborderp : std_logic; 

begin
 
--pxclk <= clk10_5;
--xpxclk <= clk10_5 when vcut='0' else clk5_25;
--hstart <= conv_std_logic_vector(H_START,10);
--vstart <= conv_std_logic_vector(V_START,9); 
--vend <= conv_std_logic_vector(311,9); 

pxclk <= clk10_5 when vvga='0' else clk21;
pxclk_en <= clk10_5_en when vvga='0' else clk21_en;
xpxsel <= vvga & vcut;
with xpxsel select xpxclk <=
  clk10_5 when "00",
  clk5_25 when "01",
    clk21 when "10",
  clk10_5 when others;

with xpxsel select xpxclk_en <=
  clk10_5_en when "00",
  clk5_25_en when "01",
			'1' when "10",
  clk10_5_en when others;

hstart <= conv_std_logic_vector(H_START,10) when vvga='0' else conv_std_logic_vector(H_START,10);
vstart <= conv_std_logic_vector(V_START,9) when hz60='0' else conv_std_logic_vector(V_START-30,9);
vend <= conv_std_logic_vector(311,9) when hz60='0' else conv_std_logic_vector(262,9); 

process(clk42)
begin
  if rising_edge(clk42) then
    clkdiv <= clkdiv + 1;  
  end if;
end process;

clk10_5_en <= '1' when clkdiv(1 downto 0) = "01" else '0';
clk21_en   <= '1' when clkdiv(0) = '0' else '0';
clk5_25_en <= '1' when clkdiv = "011" else '0';

process(RESET,clk42)
begin
 if RESET='0' then
   ink <= "1000";
	paper <= "0000";
	border <= "0000";
 elsif rising_edge(clk42) then
  if clk10_5_en = '1' then
		rinkp <= INKP;
		rpaperp <= PAPERP;
		rborderp <= BORDERP;
		if rinkp='0' and INKP='1' then
		  ink <= ink+1;
		end if;
		if rpaperp='0' and PAPERP='1' then
		  paper <= paper+1;
		end if;
		if rborderp='0' and BORDERP='1' then
		  border <= border+1;
		end if;					  
			
  end if;  
 end if;
end process;


vwe    <= '1' when RESET='0' or (cs='0' and wr='0') else '0';
vwaddr <= std_logic_vector(clrcnt) when RESET='0' else a(9 downto 0);
vwdata <= x"20" when RESET='0' else din;

process(clk42)
begin
  if rising_edge(clk42) then
    chrCode <= vidmem(conv_integer( vaVert & vaHoriz ));
	 dout <= vidmem(conv_integer( a(9 downto 0) ));
	 if vwe='1' then
	   vidmem(conv_integer( vwaddr )) <= vwdata;
	 end if;
	 -- a reset clears the screen like the real machine does: spaces, one cell per clock
	 if RESET='0' then
	   clrcnt <= clrcnt + 1;
	 end if;
	end if;
end process;

-- CP-300 character generator CI-59 (900-65): 8 scan lines per glyph,
-- lines 8-11 of the 12-line character row are blank. C0-FF show the
-- special symbols (ROM 80-BF), or the kana set (ROM C0-FF) when port EC bit 3 is set.
chraddr <= ("10" & chrCode(5 downto 0) & vpos(2 downto 0)) when chrCode(7 downto 6)="11" and kana='0' else
           (chrCode & vpos(2 downto 0));

gen_chr_pkg : if not RUNTIME_ROM generate
  process(clk42)
  begin
    if rising_edge(clk42) then
      chrRom <= CHARGEN_900_65(conv_integer( chraddr ));
    end if;
  end process;
end generate;

gen_chr_rt : if RUNTIME_ROM generate
  type clane_t is array (0 to 511) of std_logic_vector(7 downto 0);
  signal c0, c1, c2, c3 : clane_t := (others => (others => '0'));
  signal q0, q1, q2, q3 : std_logic_vector(7 downto 0) := (others => '0');
  signal clane : std_logic_vector(1 downto 0) := "00";
begin
  -- rl_waddr(12) = 1: character generator, 512 words
  process(rl_clk)
  begin
    if rising_edge(rl_clk) then
      if rl_we = '1' and rl_waddr(12) = '1' then
        c0(conv_integer(rl_waddr(8 downto 0))) <= rl_wdata(31 downto 24);
        c1(conv_integer(rl_waddr(8 downto 0))) <= rl_wdata(23 downto 16);
        c2(conv_integer(rl_waddr(8 downto 0))) <= rl_wdata(15 downto 8);
        c3(conv_integer(rl_waddr(8 downto 0))) <= rl_wdata(7 downto 0);
      end if;
    end if;
  end process;
  process(clk42)
  begin
    if rising_edge(clk42) then
      q0 <= c0(conv_integer(chraddr(10 downto 2)));
      q1 <= c1(conv_integer(chraddr(10 downto 2)));
      q2 <= c2(conv_integer(chraddr(10 downto 2)));
      q3 <= c3(conv_integer(chraddr(10 downto 2)));
      clane <= chraddr(1 downto 0);
    end if;
  end process;
  with clane select chrRom <= q0 when "00", q1 when "01", q2 when "10", q3 when others;
end generate;

process(clk42)
begin
  if rising_edge(clk42) then
	 -- 80-BF: 2x3 graphic blocks (mux CI-58), 4 dots x 4 lines each;
	 -- even code bits are the left block (shifted out first, MSB)
	 case vpos(3 downto 2) is
	   when "00"   => chrBlk <= (3 downto 0 => chrCode(0)) & (3 downto 0 => chrCode(1));
	   when "01"   => chrBlk <= (3 downto 0 => chrCode(2)) & (3 downto 0 => chrCode(3));
	   when others => chrBlk <= (3 downto 0 => chrCode(4)) & (3 downto 0 => chrCode(5));
	 end case;
	 if chrCode(7 downto 6)="10" then
	   chrSel <= "10";
	 elsif vpos(3)='1' then
	   chrSel <= "01";
	 else
	   chrSel <= "00";
	 end if;
  end if;
end process;

with chrSel select chrGrap <=
  chrBlk     when "10",
  x"00"      when "01",
  chrRom     when others;

-- h and v counters
-- 10.5 MHz pixelclock => 672 pixels per scan line
-- 312 scanlines
-- 64*8 pixels active screen = 512 pixels
-- visible area: 52*10.5 = 546
-- Horizontal: |42T-hsync|76T-porch|17T-border|512T-screen|25T-border|
process(clk42)
begin
  if rising_edge(clk42) then
    if pxclk_en = '1' then
     if hctr=671 then
	    hctr<="0000000000";
		 v1 <= not v1; 
		 if vctr>=vend then
		   vctr<="000000000";
			v1 <= '0';
		 else
			--vctr<=vctr+1;
			if v1='1' or vvga='0' then 
			  vctr<=vctr+1;
			end if; 
		 end if;
	  else
	    hctr<=hctr+1;
	  end if;
	 end if;
  end if;
end process;

--process(pxclk)
--begin
-- if falling_edge(pxclk) then
--	
--	-- 12*10.5
--	if hctr<126 or hctr>654 then
--	  hblank <= '0';
--	else
--	  hblank <= '1';
--	end if;
--	
--	if hctr<42 then -- 4*10.5
--	  hsync <= '0';
--	else
--	  hsync <= '1';
--	end if;
--	
--	if vctr<6 or vctr>309 then
--	  vblank <= '0';
--	else
--	  vblank <= '1';
--	end if;
--
--	if vctr<2 then
--	  vsync <= '0';
--	else
--	  vsync <= '1';
--	end if;
--		
-- end if;	 	 
--end process;

process(clk42)
begin
 if rising_edge(clk42) then
  if pxclk_en = '1' then
	if vvga='0' then
		-- 52 us visible, 512 active pixels inside it
		if hctr<118 or hctr>662 then
		  hblank_n <= '0';
		else
		  hblank_n <= '1';
		end if;
	else
	   -- VGA 6us
		-- 
		--if hctr<64 or hctr>662 then
		if hctr<120 or hctr>654 then
		  hblank_n <= '0';
		else
		  hblank_n <= '1';
		end if;	
	end if;
	
	if vvga='0' then	
		if hctr<42 then -- 4*10.5
		  hsync <= '0';
		else
		  hsync <= '1';
		end if;
		
		if vctr<6 or vctr>309 then
		  vblank_n <= '0';
		else
		  vblank_n <= '1';
		end if;

   else
		if hctr<79 then -- 4*21
		  hsync <= '0';
		else
		  hsync <= '1';
		end if;	
		
		if vctr<16 or vctr>257 then
		  vblank_n <= '0';
		else
		  vblank_n <= '1';
		end if;
		
   end if;
	

	if vctr<2 then
	  vsync <= '0';
	else
	  vsync <= '1';
	end if;
  end if;		
 end if;	 	 
end process; 

hact <= '1' when hctr>=hstart and hctr<hstart+512 else '0';
vact <= '1' when vctr>=vstart and vctr<vstart+192 else '0';


process(clk42)
begin
  if rising_edge(clk42) then   
   if xpxclk_en = '1' then
    if hact='1' and vact='1' then
	   if hpos=7 then
		  hpos <= "000";
		  vaHoriz <= vaHoriz+1;
		  shiftReg <= chrGrap;
		else
		  shiftReg <= shiftReg(6 downto 0) & '0';
		  hpos <= hpos+1;
		end if;
	   screen<= '1';
	 else
	   screen<= '0';
		hpos <= "111";
		vaHoriz <= (page and vcut) & "00000"; 
		shiftReg <= "00000000"; -- keep it clear
		if vctr=0 then
		  -- new frame
		  vaVert<= "0000";
		  vpos <= "0000";
		elsif vact='1' and hctr=hstart+512+2 and (v1='1' or vvga='0') then
		  -- end of a scanline
		  if vpos=11 then
		    vpos <= "0000";
			 vaVert <= vaVert+1;
		  else
		    vpos <= vpos+1;
		  end if;
		end if;
	 end if;
	end if;
  end if;
end process; 

pixel <= border when screen='0' else paper when shiftReg(7)='0' else ink;
blank <= hblank_n and vblank_n;
hblank <= not hblank_n;
vblank <= not vblank_n;
rgbi <= pixel when blank='1' else "0000";
pclk <= clk10_5 when vvga='0' else clk21;
oddline <= v1;
pix_screen <= screen;
pix_ink <= shiftReg(7);
pix_en <= pxclk_en;
ink_c <= ink;
paper_c <= paper;
border_c <= border;

-- synthesis translate_off
-- Simulation only: write the 64x16 screen to screen.txt at every frame start.
process(clk42)
  file f : text;
  variable l : line;
  variable code : integer;
  variable frame : integer := 0;
begin
  if rising_edge(clk42) then
    if vctr = 0 and hctr = 0 and pxclk_en = '1' then
      frame := frame + 1;
      file_open(f, "screen.txt", write_mode);
      write(l, string'("frame ")); write(l, frame); writeline(f, l);
      for r in 0 to 15 loop
        for c in 0 to 63 loop
          code := conv_integer(vidmem(r*64 + c));
          if code >= 32 and code < 127 then
            write(l, character'val(code));
          elsif code >= 128 and code < 192 then
            write(l, character'('#'));
          else
            write(l, character'('.'));
          end if;
        end loop;
        writeline(f, l);
      end loop;
      file_close(f);
    end if;
  end if;
end process;
-- synthesis translate_on

end Behavioral;

