-- Stand-in for roms/cp300_roms_pkg.vhd in the Pocket build.
--
-- ht1080z, cp300_rom and videoctrl are shared with the DE0 and Tang builds, which compile the ROM
-- images into the FPGA. The Pocket core loads them from the SD card instead (RUNTIME_ROM), so the
-- package is never read there; this empty one only lets the shared files compile, and no ROM
-- content, copyrighted or not, goes into the Pocket project or its bitstream.

library ieee;
use ieee.std_logic_1164.all;

package cp300_roms_pkg is
  type rom4k_t is array(0 to 4095) of std_logic_vector(7 downto 0);
  type rom2k_t is array(0 to 2047) of std_logic_vector(7 downto 0);
  constant EPROM_900_61 : rom4k_t := (others => (others => '0'));
  constant EPROM_900_62 : rom4k_t := (others => (others => '0'));
  constant EPROM_900_63 : rom4k_t := (others => (others => '0'));
  constant EPROM_900_64 : rom4k_t := (others => (others => '0'));
  constant CHARGEN_900_65 : rom2k_t := (others => (others => '0'));
end package;
