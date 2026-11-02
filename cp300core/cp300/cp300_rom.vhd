-- CP-300 system ROM: four 2732 EPROMs (CI-28..31, board revision before 2.3)
--
-- Decoder CI-44 selects one EPROM per 4 KB with A13:A12. Its second half
-- maps 3800-3BFF to the keyboard and 3C00-3FFF to video RAM, so the fourth
-- EPROM (900-64) is only reachable at 3000-37FF. The caller decodes
-- 0000-37FF; this block only picks the chip.
--
-- Contents come from roms/cp300_roms_pkg.vhd (tools/mkroms.py), or, with RUNTIME_ROM (Analogue
-- Pocket), from a RAM that the board fills at start-up with a 16 KB image from the SD card:
-- rl_wdata is written as four bytes (first byte = bits 31:24) at 32-bit word rl_waddr
-- (rl_waddr(12) = 0: system ROM, byte address 4 * rl_waddr; 1 selects the character generator,
-- see videoctrl). The image is the linear 0000-3FFF dump (the 27C128 of later boards, or
-- 900-61..64 one after the other).
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cp300_roms_pkg.all;

entity cp300_rom is
  generic (
    RUNTIME_ROM : boolean := false
  );
  port (
    clk  : in  std_logic;
    a    : in  std_logic_vector(13 downto 0);
    dout : out std_logic_vector(7 downto 0);
    rl_clk   : in  std_logic := '0';
    rl_we    : in  std_logic := '0';
    rl_waddr : in  std_logic_vector(12 downto 0) := (others => '0');
    rl_wdata : in  std_logic_vector(31 downto 0) := (others => '0')
  );
end cp300_rom;

architecture rtl of cp300_rom is

  signal q61, q62, q63, q64 : std_logic_vector(7 downto 0);
  signal sel : std_logic_vector(1 downto 0);

begin

  gen_pkg : if not RUNTIME_ROM generate
  begin
    -- one process per EPROM so each infers its own M9K ROM
    process(clk) begin
      if rising_edge(clk) then q61 <= EPROM_900_61(to_integer(unsigned(a(11 downto 0)))); end if;
    end process;
    process(clk) begin
      if rising_edge(clk) then q62 <= EPROM_900_62(to_integer(unsigned(a(11 downto 0)))); end if;
    end process;
    process(clk) begin
      if rising_edge(clk) then q63 <= EPROM_900_63(to_integer(unsigned(a(11 downto 0)))); end if;
    end process;
    process(clk) begin
      if rising_edge(clk) then q64 <= EPROM_900_64(to_integer(unsigned(a(11 downto 0)))); end if;
    end process;

    process(clk) begin
      if rising_edge(clk) then sel <= a(13 downto 12); end if;
    end process;

    with sel select dout <=
      q61 when "00",   -- CI-28 900-61 0000-0FFF
      q62 when "01",   -- CI-29 900-62 1000-1FFF
      q63 when "10",   -- CI-30 900-63 2000-2FFF
      q64 when others; -- CI-31 900-64 3000-37FF
  end generate;

  gen_rt : if RUNTIME_ROM generate
    type lane_t is array (0 to 4095) of std_logic_vector(7 downto 0);
    signal l0, l1, l2, l3 : lane_t := (others => (others => '0'));
    signal r0, r1, r2, r3 : std_logic_vector(7 downto 0) := (others => '0');
    signal lane : std_logic_vector(1 downto 0) := "00";
  begin
    -- four byte lanes, written a word at a time from rl_clk, read a byte at a time from clk
    process(rl_clk) begin
      if rising_edge(rl_clk) then
        if rl_we = '1' and rl_waddr(12) = '0' then
          l0(to_integer(unsigned(rl_waddr(11 downto 0)))) <= rl_wdata(31 downto 24);
          l1(to_integer(unsigned(rl_waddr(11 downto 0)))) <= rl_wdata(23 downto 16);
          l2(to_integer(unsigned(rl_waddr(11 downto 0)))) <= rl_wdata(15 downto 8);
          l3(to_integer(unsigned(rl_waddr(11 downto 0)))) <= rl_wdata(7 downto 0);
        end if;
      end if;
    end process;
    process(clk) begin
      if rising_edge(clk) then
        r0 <= l0(to_integer(unsigned(a(13 downto 2))));
        r1 <= l1(to_integer(unsigned(a(13 downto 2))));
        r2 <= l2(to_integer(unsigned(a(13 downto 2))));
        r3 <= l3(to_integer(unsigned(a(13 downto 2))));
        lane <= a(1 downto 0);
      end if;
    end process;
    with lane select dout <=
      r0 when "00",
      r1 when "01",
      r2 when "10",
      r3 when others;
  end generate;

end rtl;
