-- BeagleV-Fire multicore copy (syn/beaglev-fire/mc1000): renamed from mc6847_romchar (rom/MC6847_romchar.vhd) of the Multicore MC1000 core; the 6847's character set, unchanged otherwise
--
-- Multicore 2 / Multicore 2+
--
-- Copyright (c) 2017-2020 - Victor Trucco
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
-- THIS CODE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
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
-- You are responsible for any legal issues arising from your use of this code.
--
		
-- generated with romgen v3.0 by MikeJ
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity mc1000_vdg_chr is
	port (
		clk		: in    std_logic;
		addr		: in    std_logic_vector(9 downto 0);
		data		: out   std_logic_vector(7 downto 0)
	);
end;

architecture rtl of mc1000_vdg_chr is

	type ROM_ARRAY is array(0 to 1023) of std_logic_vector(7 downto 0);
	constant ROM : ROM_ARRAY := (
		x"00",x"00",x"00",x"1C",x"22",x"02",x"1A",x"2A", -- 0x0000
		x"2A",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0008
		x"00",x"00",x"00",x"08",x"14",x"22",x"22",x"3E", -- 0x0010
		x"22",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0018
		x"00",x"00",x"00",x"3C",x"12",x"12",x"1C",x"12", -- 0x0020
		x"12",x"3C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0028
		x"00",x"00",x"00",x"1C",x"22",x"20",x"20",x"20", -- 0x0030
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0038
		x"00",x"00",x"00",x"3C",x"12",x"12",x"12",x"12", -- 0x0040
		x"12",x"3C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0048
		x"00",x"00",x"00",x"3E",x"20",x"20",x"38",x"20", -- 0x0050
		x"20",x"3E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0058
		x"00",x"00",x"00",x"3E",x"20",x"20",x"38",x"20", -- 0x0060
		x"20",x"20",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0068
		x"00",x"00",x"00",x"1E",x"20",x"20",x"26",x"22", -- 0x0070
		x"22",x"1E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0078
		x"00",x"00",x"00",x"22",x"22",x"22",x"3E",x"22", -- 0x0080
		x"22",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0088
		x"00",x"00",x"00",x"1C",x"08",x"08",x"08",x"08", -- 0x0090
		x"08",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0098
		x"00",x"00",x"00",x"02",x"02",x"02",x"02",x"22", -- 0x00A0
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x00A8
		x"00",x"00",x"00",x"22",x"24",x"28",x"30",x"28", -- 0x00B0
		x"24",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x00B8
		x"00",x"00",x"00",x"20",x"20",x"20",x"20",x"20", -- 0x00C0
		x"20",x"3E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x00C8
		x"00",x"00",x"00",x"22",x"36",x"2A",x"2A",x"22", -- 0x00D0
		x"22",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x00D8
		x"00",x"00",x"00",x"22",x"32",x"2A",x"26",x"22", -- 0x00E0
		x"22",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x00E8
		x"00",x"00",x"00",x"3E",x"22",x"22",x"22",x"22", -- 0x00F0
		x"22",x"3E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x00F8
		x"00",x"00",x"00",x"3C",x"22",x"22",x"3C",x"20", -- 0x0100
		x"20",x"20",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0108
		x"00",x"00",x"00",x"1C",x"22",x"22",x"22",x"2A", -- 0x0110
		x"24",x"1A",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0118
		x"00",x"00",x"00",x"3C",x"22",x"22",x"3C",x"28", -- 0x0120
		x"24",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0128
		x"00",x"00",x"00",x"1C",x"22",x"10",x"08",x"04", -- 0x0130
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0138
		x"00",x"00",x"00",x"3E",x"08",x"08",x"08",x"08", -- 0x0140
		x"08",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0148
		x"00",x"00",x"00",x"22",x"22",x"22",x"22",x"22", -- 0x0150
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0158
		x"00",x"00",x"00",x"22",x"22",x"22",x"14",x"14", -- 0x0160
		x"08",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0168
		x"00",x"00",x"00",x"22",x"22",x"22",x"2A",x"2A", -- 0x0170
		x"36",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0178
		x"00",x"00",x"00",x"22",x"22",x"14",x"08",x"14", -- 0x0180
		x"22",x"22",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0188
		x"00",x"00",x"00",x"22",x"22",x"14",x"08",x"08", -- 0x0190
		x"08",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0198
		x"00",x"00",x"00",x"3E",x"02",x"04",x"08",x"10", -- 0x01A0
		x"20",x"3E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x01A8
		x"00",x"00",x"00",x"38",x"20",x"20",x"20",x"20", -- 0x01B0
		x"20",x"38",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x01B8
		x"00",x"00",x"00",x"20",x"20",x"10",x"08",x"04", -- 0x01C0
		x"02",x"02",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x01C8
		x"00",x"00",x"00",x"0E",x"02",x"02",x"02",x"02", -- 0x01D0
		x"02",x"0E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x01D8
		x"00",x"00",x"00",x"08",x"1C",x"2A",x"08",x"08", -- 0x01E0
		x"08",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x01E8
		x"00",x"00",x"00",x"00",x"08",x"10",x"3E",x"10", -- 0x01F0
		x"08",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x01F8
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0200
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0208
		x"00",x"00",x"00",x"08",x"08",x"08",x"08",x"08", -- 0x0210
		x"00",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0218
		x"00",x"00",x"00",x"14",x"14",x"14",x"00",x"00", -- 0x0220
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0228
		x"00",x"00",x"00",x"14",x"14",x"36",x"00",x"36", -- 0x0230
		x"14",x"14",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0238
		x"00",x"00",x"00",x"08",x"1E",x"20",x"1C",x"02", -- 0x0240
		x"3C",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0248
		x"00",x"00",x"00",x"32",x"32",x"04",x"08",x"10", -- 0x0250
		x"26",x"26",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0258
		x"00",x"00",x"00",x"10",x"28",x"28",x"10",x"2A", -- 0x0260
		x"24",x"1A",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0268
		x"00",x"00",x"00",x"18",x"18",x"18",x"00",x"00", -- 0x0270
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0278
		x"00",x"00",x"00",x"08",x"10",x"20",x"20",x"20", -- 0x0280
		x"10",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0288
		x"00",x"00",x"00",x"08",x"04",x"02",x"02",x"02", -- 0x0290
		x"04",x"08",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0298
		x"00",x"00",x"00",x"00",x"08",x"1C",x"3E",x"1C", -- 0x02A0
		x"08",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02A8
		x"00",x"00",x"00",x"00",x"08",x"08",x"3E",x"08", -- 0x02B0
		x"08",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02B8
		x"00",x"00",x"00",x"00",x"00",x"00",x"30",x"30", -- 0x02C0
		x"10",x"20",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02C8
		x"00",x"00",x"00",x"00",x"00",x"00",x"3E",x"00", -- 0x02D0
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02D8
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02E0
		x"30",x"30",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02E8
		x"00",x"00",x"00",x"02",x"02",x"04",x"08",x"10", -- 0x02F0
		x"20",x"20",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x02F8
		x"00",x"00",x"00",x"18",x"24",x"24",x"24",x"24", -- 0x0300
		x"24",x"18",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0308
		x"00",x"00",x"00",x"08",x"18",x"08",x"08",x"08", -- 0x0310
		x"08",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0318
		x"00",x"00",x"00",x"1C",x"22",x"02",x"1C",x"20", -- 0x0320
		x"20",x"3E",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0328
		x"00",x"00",x"00",x"1C",x"22",x"02",x"04",x"02", -- 0x0330
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0338
		x"00",x"00",x"00",x"04",x"0C",x"14",x"3E",x"04", -- 0x0340
		x"04",x"04",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0348
		x"00",x"00",x"00",x"3E",x"20",x"3C",x"02",x"02", -- 0x0350
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0358
		x"00",x"00",x"00",x"1C",x"20",x"20",x"3C",x"22", -- 0x0360
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0368
		x"00",x"00",x"00",x"3E",x"02",x"04",x"08",x"10", -- 0x0370
		x"20",x"20",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0378
		x"00",x"00",x"00",x"1C",x"22",x"22",x"1C",x"22", -- 0x0380
		x"22",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0388
		x"00",x"00",x"00",x"1C",x"22",x"22",x"1E",x"02", -- 0x0390
		x"02",x"1C",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x0398
		x"00",x"00",x"00",x"00",x"18",x"18",x"00",x"18", -- 0x03A0
		x"18",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x03A8
		x"00",x"00",x"00",x"18",x"18",x"00",x"18",x"18", -- 0x03B0
		x"08",x"10",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x03B8
		x"00",x"00",x"00",x"04",x"08",x"10",x"20",x"10", -- 0x03C0
		x"08",x"04",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x03C8
		x"00",x"00",x"00",x"00",x"00",x"3E",x"00",x"3E", -- 0x03D0
		x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x03D8
		x"00",x"00",x"00",x"10",x"08",x"04",x"02",x"04", -- 0x03E0
		x"08",x"10",x"00",x"00",x"00",x"00",x"00",x"00", -- 0x03E8
		x"00",x"00",x"00",x"18",x"24",x"04",x"08",x"08", -- 0x03F0
		x"00",x"08",x"00",x"00",x"00",x"00",x"00",x"00"  -- 0x03F8
	);

begin

	process(clk)
	begin
		if rising_edge(clk) then
			data <= ROM(to_integer(unsigned(addr)));
		end if;
	end process;
end RTL;
