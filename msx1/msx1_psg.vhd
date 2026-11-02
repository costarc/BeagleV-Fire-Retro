-- msx1_psg.vhd: the OCM's PSG (ocm/psg.vhd) for the MSX1 (bvf_msx1.v), with its joystick ports pulled up here
-- (they are inout and the PSG drives some bits low: Verilog cannot give them a weak pull-up).
library ieee;
use ieee.std_logic_1164.all;

entity msx1_psg is
	port (
		clk      : in  std_logic;
		ena21    : in  std_logic;
		reset    : in  std_logic;
		clkena   : in  std_logic;
		req      : in  std_logic;
		wrt      : in  std_logic;
		adr      : in  std_logic_vector(15 downto 0);
		dbi      : out std_logic_vector(7 downto 0);
		dbo      : in  std_logic_vector(7 downto 0);
		wave     : out std_logic_vector(7 downto 0);
		cmtin    : in  std_logic := '0'                  -- the cassette input (register 14, bit 7)
	);
end msx1_psg;

architecture rtl of msx1_psg is
	component psg
		port (
			clk21m, ena21, reset, clkena, req : in std_logic;
			ack : out std_logic;
			wrt : in std_logic;
			adr : in std_logic_vector(15 downto 0);
			dbi : out std_logic_vector(7 downto 0);
			dbo : in std_logic_vector(7 downto 0);
			joya : inout std_logic_vector(5 downto 0);
			stra : out std_logic;
			joyb : inout std_logic_vector(5 downto 0);
			strb : out std_logic;
			kana : out std_logic;
			cmtin, keymode : in std_logic;
			wave : out std_logic_vector(7 downto 0));
	end component;
	signal joya, joyb : std_logic_vector(5 downto 0);
begin
	joya <= (others => 'H');
	joyb <= (others => 'H');
	u : psg
		port map (clk21m => clk, ena21 => ena21, reset => reset, clkena => clkena, req => req, ack => open, wrt => wrt, adr => adr,
			dbi => dbi, dbo => dbo, joya => joya, stra => open, joyb => joyb, strb => open, kana => open, cmtin => cmtin, keymode => '1',
			wave => wave);
end rtl;
