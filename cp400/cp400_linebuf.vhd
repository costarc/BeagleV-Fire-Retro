-- MC6847 line buffer of the CP-400 core: 512 x 8, one write port and one registered read port, one clock.
-- Replaces the Altera altsyncram dual-port RAM (dpram_1r1w) of the original.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cp400_linebuf is
	port (
		clk       : in  std_logic;
		we        : in  std_logic;
		wraddress : in  std_logic_vector(8 downto 0);
		data      : in  std_logic_vector(7 downto 0);
		rdaddress : in  std_logic_vector(8 downto 0);
		q         : out std_logic_vector(7 downto 0)
	);
end cp400_linebuf;

architecture rtl of cp400_linebuf is
	type ram_t is array (0 to 511) of std_logic_vector(7 downto 0);
	signal ram : ram_t;
begin
	process (clk)
	begin
		if rising_edge(clk) then
			if we = '1' then
				ram(to_integer(unsigned(wraddress))) <= data;
			end if;
			q <= ram(to_integer(unsigned(rdaddress)));
		end if;
	end process;
end rtl;
