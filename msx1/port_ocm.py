#!/usr/bin/env python3
"""Copy the OCM-PLD (KdL's OneChip MSX) PSG sources and give them a clock enable (the MSX1 uses the PSG; the MSX2 that
also used the OCM's VDP was removed from the design).

The OCM runs its VDP and sound on a 21.477 MHz clock.  The BeagleV-Fire design has one 42 MHz core clock;
21.477 MHz is exactly 45/88 of it, so the machine runs on the 42 MHz clock with an enable (ENA21).

What the script does to every file (the licence headers stay untouched, one note line is added at the top):
  * a port  ENA21 : IN STD_LOGIC  after every CLK21M port (entities and components),
  * ENA21 => ENA21 after every CLK21M => CLK21M in a port map,
  * the body of every  IF/ELSIF (CLK21M'EVENT AND CLK21M = '1') THEN ... END IF  is wrapped in  IF ENA21 = '1' THEN ... END IF
    (nested, not "and ena" in the clock condition: Synplify makes a clock enable out of the nesting only).
The small RAMs (CLK / INCLOCK ports) get the enable too: two enables can fall on adjacent 42 MHz clocks and a RAM with one clock of latency would then return stale data.

usage: python3 port_ocm.py [path to ocm-pld-dev/esemsx3/src]
"""
import re
import sys
import glob
import os

src = sys.argv[1] if len(sys.argv) > 1 else '/c/Users/roniv/Dev/github/ocm-pld-dev/esemsx3/src'
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'ocm')
os.makedirs(out, exist_ok=True)

files = [src + '/sound/psg/psg.vhd', src + '/sound/psg/psg_wave.vhd']

CLKS = r"(?:CLK21M|CLK|INCLOCK)"
EDGE = re.compile(r"^(?P<pre>\s*)(?P<kw>ELSIF|IF)\s*\(\s*(?P<clk>" + CLKS + r")\s*'EVENT\s+AND\s+(?P=clk)\s*=\s*'1'\s*\)\s*THEN(?P<post>.*)$", re.I)
PORT = re.compile(r"^(?P<pre>\s*)" + CLKS + r"\s*:\s*IN\s+STD_LOGIC\s*;(?P<post>.*)$", re.I)
MAP = re.compile(r"^(?P<pre>\s*)" + CLKS + r"\s*=>\s*CLK21M\s*,(?P<post>.*)$", re.I)
PORT_LAST = re.compile(r"^(?P<pre>\s*)" + CLKS + r"\s*:\s*IN\s+STD_LOGIC\s*$", re.I)


def code(line):
    return line.split('--')[0]


def convert(text):
    lines = text.split('\n')
    res = []
    i = 0
    n_edge = n_port = n_map = 0
    pending_end = []    # (depth counter) for open ENA wrappers
    # first pass: ports / maps
    for ln in lines:
        m = PORT.match(code(ln))
        if m:
            res.append(ln)
            res.append(m.group('pre') + 'ENA21               : IN    STD_LOGIC;')
            n_port += 1
            continue
        m = MAP.match(code(ln))
        if m:
            res.append(ln)
            res.append(m.group('pre') + 'ENA21               => ENA21,')
            n_map += 1
            continue
        if PORT_LAST.match(code(ln)):
            raise SystemExit('CLK21M is the last port of an entity: not handled: ' + ln)
        res.append(ln)
    lines = res
    # second pass: wrap the clocked bodies
    res = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = EDGE.match(code(ln))
        if not m:
            res.append(ln)
            i += 1
            continue
        n_edge += 1
        res.append(ln)
        res.append(m.group('pre') + '    IF( ENA21 = \'1\' )THEN')
        depth = 0
        i += 1
        while True:
            c = code(lines[i])
            # "END IF" closes, other IF opens ("ELSIF" and "ELSE IF" do not match the word IF at a boundary except "ELSE IF")
            ends = len(re.findall(r'\bEND\s+IF\b', c, re.I))
            opens = len(re.findall(r'\bIF\b', c, re.I)) - ends
            if depth == 0 and ends > 0 and opens == 0 and re.match(r'^\s*END\s+IF\s*;', c, re.I):
                res.append(m.group('pre') + '    END IF;')
                res.append(lines[i])
                break
            depth += opens - ends
            res.append(lines[i])
            i += 1
        i += 1
    return '\n'.join(res), n_edge, n_port, n_map




def no_vga(t):
    # the 31 kHz VGA scan doubler (two line buffers) is not wanted: 15 kHz RGB only, the DispReso input is ignored
    t, n = re.subn(r"    U_VDP_VGA: VDP_VGA\s*PORT MAP\(.*?\n    \);\n", "    BLANK_O <= '0';\n", t, flags=re.S)
    assert n == 1
    for sig in ('R', 'G', 'B'):
        t, n = re.subn(r"PVIDEO%s\s*<=\s*IVIDEO%s_NTSC_PAL WHEN\( DISPMODEVGA = '0' \)ELSE\s*IVIDEO%s_VGA;" % (sig, sig, sig), "PVIDEO%s <= IVIDEO%s_NTSC_PAL;" % (sig, sig), t)
        assert n == 1
    for sig in ('HS', 'VS'):
        t, n = re.subn(r"PVIDEO%s_N\s*<=\s*IVIDEO%s_N_NTSC_PAL WHEN\( DISPMODEVGA = '0' \)ELSE\s*IVIDEO%s_N_VGA;" % (sig, sig, sig), "PVIDEO%s_N <= IVIDEO%s_N_NTSC_PAL;" % (sig, sig), t)
        assert n == 1
    return t


tot = [0, 0, 0]
for f in files:
    name = os.path.basename(f)
    text = open(f, encoding='utf-8', errors='replace').read()
    if not re.search(CLKS, text, re.I):
        new, e, p, mp = text, 0, 0, 0
    else:
        new, e, p, mp = convert(text)
    if name == 'vdp.vhd':
        new = no_vga(new)
    note = '-- Modified for the BeagleV-Fire multicore (syn/beaglev-fire/msx1/port_ocm.py): clock enable ENA21 added; the original is OCM-PLD by KdL / ESE Artists\' Factory.\n'
    open(os.path.join(out, name.lower()), 'w', encoding='utf-8', newline='\n').write(note + new)
    tot[0] += e
    tot[1] += p
    tot[2] += mp
    print('%-22s edge %3d  ports %2d  maps %2d' % (name, e, p, mp))
print('total edge %d ports %d maps %d' % tuple(tot))
