"""Diagrams 6 - 15 of the technical paper (imported by make_figures.py)."""
import os
import sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fig_lib import *   # noqa
import matplotlib.pyplot as plt


def out(name):
    return os.path.join(HERE, name)


# ------------------------------------------------------------------------------------------------------------ 6  CP-400
def fig_cp400():
    fig, ax = canvas(100, 66)
    group(ax, 1, 1, 98, 64, "CP-400 / CoCo 2 (machine 1): the 6809 machine, no Z80", "m_6809")
    box(ax, 4, 44, 20, 14, "cpu09 (6809)\n2,942 LUT\nthe biggest block of the\nwhole design", "m_6809", fs=7)
    box(ax, 30, 44, 18, 14, "mc6883 SAM\n264 LUT\naddress mux, RAM\nrefresh, video fetch", "m_6809", fs=7)
    box(ax, 54, 44, 18, 14, "mc6847 VDG\n272 LUT + char ROM\n256 x 192, 11 colours", "m_6809", fs=7)
    box(ax, 78, 44, 19, 14, "2 x PIA 6821\n189 LUT\nkeys, tape, sound\njoysticks centred", "m_6809", fs=7)
    box(ax, 4, 26, 20, 12, "ROM: Color BASIC +\nExtended BASIC,\n8 KB each (pool blocks,\nloaded by the host)", "shared", fs=6.8)
    box(ax, 30, 26, 18, 12, "RAM 64 KB\n(pool, shared)\nwrite at the end\nof the SAM pulse", "shared", fs=6.8)
    box(ax, 54, 26, 18, 12, "frame capture\n(bvf_fb direct mode)\n4 bit colour index", "shared", fs=6.8)
    box(ax, 78, 26, 19, 12, "tape (bvf_tape)\nPIA1 PA0 in,\nDAC top bit out,\nCA2 motor", "shared", fs=6.8)
    box(ax, 4, 6, 28, 14, "floppy card $FF40-$FF4F (bvf_cocofdc)\nthe CP-300's WD1793 on its\nsecond bus, 256 B sectors,\nHALT on DRQ, NMI on INTRQ", "fabric", fs=6.8)
    box(ax, 38, 6, 28, 14, "MiniIDE $FF50-$FF5F (bvf_ide)\nATA PIO, LBA28, 461 LUT\nsector window at 0x40000;\nDOS cartridge ROM (HDB-DOS)", "fabric", fs=6.8)
    box(ax, 72, 6, 25, 14, "host: daemon answers\nsector requests (IRQ),\nimages: .DSK / .JVC / raw", "host", fs=6.8)
    arrow(ax, (24, 51), (30, 51), both=True)
    arrow(ax, (48, 51), (54, 51), both=True)
    arrow(ax, (72, 51), (78, 51), both=True)
    arrow(ax, (14, 44), (14, 38))
    arrow(ax, (39, 44), (39, 38), both=True)
    arrow(ax, (63, 44), (63, 38))
    arrow(ax, (87, 44), (87, 38), both=True)
    arrow(ax, (18, 20), (18, 44), both=True, rad=0.0, ls="--", color="#7A3FB0")
    arrow(ax, (50, 20), (45, 44), both=True, ls="--", color="#7A3FB0")
    arrow(ax, (66, 13), (72, 13), both=True)
    arrow(ax, (32, 13), (38, 13), both=True)
    label(ax, 50, 62.2, "", fs=6)
    label(ax, 50, 3, "Clock: the 42 MHz core clock with an enable of exactly 15/44 (= 14.318 MHz); E = 0.894 MHz, real NTSC speed.", fs=6.5, italic=True)
    save(fig, out("fig06_cp400.png"))


# ------------------------------------------------------------------------------------------------------------ 7  MSX1
def fig_msx1():
    fig, ax = canvas(100, 70)
    group(ax, 1, 20, 62, 49, "MSX1 (machine 2), bvf_msx1", "m_z80")
    box(ax, 3, 52, 16, 12, "shared Z80\n3.58 MHz\n= ena21 / 6", "shared", fs=7)
    box(ax, 23, 52, 18, 12, "slot logic\nPPI (slot select,\nkeyboard, motor)", "m_z80", fs=7)
    box(ax, 45, 52, 16, 12, "PSG (OCM)\nAY-3-8910\n+ tape in", "m_z80", fs=7)
    box(ax, 3, 36, 26, 12, "vdp18: TMS9918A\non ena21 / 2 (10.74 MHz)\nsprites, 4 screen modes", "m_z80", fs=7)
    box(ax, 33, 36, 28, 12, "VRAM 16 KB on chip\n8 pool blocks (2K x 10)\nfetched every few dot clocks", "shared", fs=7, bold=True)
    box(ax, 3, 22, 26, 11, "Slot 0: BIOS + BASIC 32 KB\n(+ 16 KB page-2 ROM)", "ext", fs=6.8)
    box(ax, 33, 22, 28, 11, "Slot 1: cartridge up to 32 KB\nSlot 2: disk interface ROM 16 KB", "ext", fs=6.8)
    group(ax, 66, 20, 33, 49, "DDR via FIC0 (AXI, 125 MHz)", "shared")
    box(ax, 68, 52, 29, 12, "ROMs in DDR (BASE $C800_0000)\nBIOS +$620000, page-2 +$63C000\ncartridge +$640000, disk +$648000", "shared", fs=6.5)
    box(ax, 68, 36, 29, 12, "8 KB read cache (pool blocks)\n1024 lines x 8 B, direct mapped\nhit: no wait; miss: WAIT until\none 64-bit word is in", "shared", fs=6.5)
    box(ax, 68, 22, 29, 11, "read latency measured:\n256 ns typical, up to 1.09 us\n(Z80 memory cycle = 840 ns)", "ok", fs=6.5)
    box(ax, 1, 3, 30, 12, "Slot 3: 64 KB RAM (pool)\nno wait state", "shared", fs=7)
    box(ax, 35, 3, 30, 12, "Disk interface (slot 2)\nregisters $7FB8-$7FBC and mirror in\npage 2 ($BFB8-$BFBC); shared WD1793", "fabric", fs=6.5)
    box(ax, 69, 3, 30, 12, "frame capture: colour index\n256 x 192 (240 in text mode)\nto bvf_fb", "shared", fs=7)
    arrow(ax, (19, 58), (23, 58), both=True)
    arrow(ax, (41, 58), (45, 58), both=True)
    arrow(ax, (11, 52), (11, 48), both=True)
    arrow(ax, (29, 42), (33, 42), both=True)
    arrow(ax, (61, 27), (68, 41), both=True, ls="--")
    arrow(ax, (11, 22), (11, 15), both=True)
    save(fig, out("fig07_msx1.png"))


# ------------------------------------------------------------------------------------------------------------ 8  ZX ULA slots
def fig_zx():
    fig, ax = canvas(100, 50)
    label(ax, 50, 47.6, "ZX Spectrum: one T-state = 12 core clocks, one read port in the pool", fs=8.2, bold=True)
    x0 = 6
    cw = 7.1
    names = ["Z80\naddress", "Z80\naddress", "ULA reads\nbitmap", "ULA reads\nattribute", "Z80\naddress", "Z80\naddress", "Z80\naddress", "Z80\naddress", "Z80\naddress", "Z80\naddress", "Z80\naddress", "Z80\naddress"]
    for i in range(12):
        kind = "m_soft" if i in (2, 3) else "m_z80"
        box(ax, x0 + i * cw, 28, cw - 0.4, 9, names[i], kind, fs=5.6)
        label(ax, x0 + i * cw + (cw - 0.4) / 2, 25.6, "tc %d" % i, fs=6, color="#555555")
    label(ax, 3, 32.5, "read\nport", fs=6.5, bold=True)
    # data return
    box(ax, x0 + 3 * cw, 15.5, cw - 0.4, 6, "bm_n\nlatched", "m_soft", fs=5.6)
    box(ax, x0 + 4 * cw, 15.5, cw - 0.4, 6, "at_n\nlatched", "m_soft", fs=5.6)
    box(ax, x0 + 11 * cw, 15.5, cw - 0.4, 6, "Z80 takes\ndata (cen)", "m_z80", fs=5.6)
    label(ax, 3, 18.5, "data\n(1 clk\nlater)", fs=6.2, bold=True)
    arrow(ax, (x0 + 2.5 * cw, 28), (x0 + 3.5 * cw, 21.6), color="#B03A3A")
    arrow(ax, (x0 + 3.5 * cw, 28), (x0 + 4.5 * cw, 21.6), color="#B03A3A")
    arrow(ax, (x0 + 10.5 * cw, 28), (x0 + 11.5 * cw, 21.6), color="#2F5FB3")
    # character cell strip
    label(ax, 50, 11.5, "A character cell = 8 pixels = 4 T-states; the fetch for the NEXT cell is in its second T-state:", fs=6.5, italic=True)
    for i in range(4):
        kind = "m_soft" if i == 1 else "none"
        box(ax, 20 + i * 15, 2.4, 14, 7.4, "T-state %d%s" % (i + 1, "\nfetch bitmap,\nattribute" if i == 1 else ""), kind, fs=5.8)
    label(ax, 3, 6, "cell", fs=6.5, bold=True)
    label(ax, 50, 0.6, "The Z80 samples its data at the last clock (tc 11), so it never sees the ULA's bytes. Picture 256 x 192, 448 x 312 pixels per frame, 50.08 Hz.", fs=5.8, italic=True)
    save(fig, out("fig08_zx.png"))


# ------------------------------------------------------------------------------------------------------------ 9  MC-1000 + Alice
def fig_alice():
    fig, ax = canvas(100, 66)
    group(ax, 1, 36, 98, 29, "MC-1000 (machine 4): all in the fabric", "m_z80")
    box(ax, 4, 41, 16, 17, "shared Z80\n3.58 MHz", "shared", fs=7)
    box(ax, 24, 41, 20, 17, "RAM $0000-$BFFF\nROM $C000-$FFFF\n(pool, ROM loaded\nby the host)", "shared", fs=6.8)
    box(ax, 48, 41, 22, 17, "MC6847 VDG\n(Trucco's MC1000 core)\nreads its VRAM itself\n(8 KB, pool VRAM port)", "m_z80", fs=6.8)
    box(ax, 74, 41, 22, 17, "PSG (OCM)\nkeyboard: port A rows,\nport B columns\nINT: 8.8 us / 3.45 ms", "m_z80", fs=6.8)
    arrow(ax, (20, 49), (24, 49), both=True)

    group(ax, 1, 1, 44, 32, "Alice (machine 5): the host is the CPU", "m_soft")
    box(ax, 3, 14, 40, 15, "alice_emu (C process on Linux)\nMC6803 (894,886 Hz), 4 KB RAM, 8 KB ROM,\nkeyboard matrix, 1-bit sound, tape edges\n0.2-0.3 M instructions/s, ~1 ms slices", "m_soft", fs=6.2)
    box(ax, 3, 3, 40, 8, "register window over /dev/uio0\n(32-bit accesses, no per-cycle traffic)", "host", fs=6.3)
    group(ax, 60, 1, 39, 32, "Fabric (bvf_mc1000, alice = 1)", "fabric")
    box(ax, 62, 22, 35, 8, "VDG: mode from the $BFFF latch;\nper byte b7 = A/S, b6 = INV;\npicture to bvf_fb as the MC-1000's", "m_z80", fs=5.9)
    box(ax, 62, 13, 16, 7, "VRAM 6 KB", "shared", fs=6.0)
    box(ax, 81, 13, 16, 7, "audio edge FIFO\n(b7 = 1-bit DAC)", "shared", fs=6.0)
    box(ax, 62, 3, 35, 8, "bvf_regs: window 0x60000 (VRAM words),\nlatch 0xA0 ($BFFF value), KEYS registers", "fabric", fs=6.0)
    arrow(ax, (45, 9.5), (62, 9.5), "VRAM words", toff=(0, 1.6), fs=5.6)
    arrow(ax, (45, 7), (62, 7), "$BFFF", toff=(0, 1.6), fs=5.6)
    arrow(ax, (62, 4.5), (45, 4.5), "keys", toff=(0, 1.6), fs=5.6)
    arrow(ax, (70, 11), (70, 13), ls="--")
    arrow(ax, (89, 11), (89, 13), ls="--")
    save(fig, out("fig09_alice.png"))


# ------------------------------------------------------------------------------------------------------------ 10  why a soft CPU
def fig_softcpu():
    fig, axs = plt.subplots(1, 2, figsize=(6.8, 3.3), dpi=200, gridspec_kw={"width_ratios": [1.15, 1]})
    ax = axs[0]
    names = ["free on the chip\n(gateware 4328)", "cpu09 (6809)", "T80s (Z80)", "Alice glue:\nVDG reuse, window"]
    vals = [22956 - 21659, 2942, 2450, 60]
    cols = ["#6FBF9F", "#B38FD6", "#7FA6D6", "#E07A7A"]
    y = [3, 2, 1, 0]
    ax.barh(y, vals, color=cols, ec="#333333", lw=0.6, height=0.62)
    for yy, v in zip(y, vals):
        ax.text(v + 60, yy, "%s LUT" % format(v, ","), va="center", fontsize=6.6)
    ax.set_yticks(y)
    ax.set_yticklabels(names, fontsize=6.6)
    ax.set_xlim(0, 4200)
    ax.set_title("Logic: a second CPU core does not fit", fontsize=7.4, fontweight="bold")
    ax.tick_params(axis="x", labelsize=6.3)
    ax.text(2100, -0.95, "T80s: 2.3-2.6K measured in different builds;\n80 of 84 block RAMs are in use too", fontsize=5.8, ha="center", style="italic")
    ax.set_ylim(-1.5, 3.6)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax = axs[1]
    labels = ["needed by the\nAlice (6803, 0.9 MHz)", "PC, mingw -O2\n(best case)", "U54 hart\n(estimate)"]
    vals = [0.25, 165, 7.5]
    cols = ["#E07A7A", "#9BB0C8", "#9BB0C8"]
    ax.barh([2, 1, 0], vals, color=cols, ec="#333333", lw=0.6, height=0.62)
    ax.set_xscale("log")
    ax.set_xlim(0.1, 1500)
    for yy, v, t in zip([2, 1, 0], vals, ["0.2-0.3", "165", "5-10 (not measured)"]):
        ax.text(v * 1.25, yy, t + " M/s", va="center", fontsize=6.4)
    ax.set_yticks([2, 1, 0])
    ax.set_yticklabels(labels, fontsize=6.6)
    ax.set_title("Speed: about 2-5 % of one hart", fontsize=7.4, fontweight="bold")
    ax.tick_params(axis="x", labelsize=6.3)
    ax.set_xlabel("instructions per second (log scale)", fontsize=6.4)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    save(fig, out("fig10_softcpu.png"))


# ------------------------------------------------------------------------------------------------------------ 11  MSX2 VRAM / DDR
def fig_vram():
    fig, axs = plt.subplots(1, 2, figsize=(6.8, 3.6), dpi=200)
    ax = axs[0]
    names = ["VDP dot clock\n(10.74 MHz)", "Z80 T-state\n(3.58 MHz)", "DDR write\n(typical)", "DDR read\n(typical)", "Z80 memory\ncycle", "DDR read\n(worst seen)"]
    vals = [93, 280, 64, 256, 840, 1088]
    cols = ["#E07A7A", "#9BB0C8", "#E0A94A", "#E0A94A", "#9BB0C8", "#C0392B"]
    y = list(range(len(vals)))[::-1]
    ax.barh(y, vals, color=cols, ec="#333333", lw=0.6, height=0.62)
    for yy, v in zip(y, vals):
        ax.text(v + 25, yy, "%d ns" % v, va="center", fontsize=6.4)
    ax.set_yticks(y)
    ax.set_yticklabels(names, fontsize=6.2)
    ax.set_xlim(0, 1500)
    ax.set_title("Why the VRAM cannot be in DDR", fontsize=7.4, fontweight="bold")
    ax.tick_params(axis="x", labelsize=6.2)
    ax.set_xlabel("ns (measured on the board with the DDR probe)", fontsize=6.2)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax = axs[1]
    names = ["MSX2 VRAM 128 KB,\nnatural (2 blocks / word)", "MSX2 VRAM 128 KB,\npacked (read-modify-write)", "MSX1 VRAM 16 KB\n(what the design uses)"]
    vals = [64, 56, 8]
    cols = ["#C0392B", "#E0A94A", "#6FBF9F"]
    y = [2, 1, 0]
    ax.barh(y, vals, color=cols, ec="#333333", lw=0.6, height=0.62)
    for yy, v in zip(y, vals):
        ax.text(v + 1, yy, "%d blocks" % v, va="center", fontsize=6.4)
    ax.axvline(63, color="#1E7B6B", ls="--", lw=1.1)
    ax.text(62.5, 2.5, "63 free at best", color="#1E7B6B", fontsize=6.2, ha="right")
    ax.set_yticks(y)
    ax.set_yticklabels(names, fontsize=6.2)
    ax.set_xlim(0, 80)
    ax.set_ylim(-0.6, 2.9)
    ax.set_title("Block RAM needed for the VRAM", fontsize=7.4, fontweight="bold")
    ax.tick_params(axis="x", labelsize=6.2)
    ax.set_xlabel("LSRAM blocks (20 Kbit each; the chip has 84)", fontsize=6.2)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    save(fig, out("fig11_vram.png"))


# ------------------------------------------------------------------------------------------------------------ 12  disks
def fig_disk():
    fig, ax = canvas(100, 66)
    group(ax, 1, 40, 44, 25, "Three front ends, one WD1793", "m_z80")
    box(ax, 3, 52, 40, 7, "CP-300: the controller's own ports;\nDMK and HDV images", "m_z80", fs=6.2)
    box(ax, 3, 45.5, 40, 5.5, "CP-400: $FF40 card, HALT on DRQ, NMI; 256 B sectors", "m_6809", fs=6.0)
    box(ax, 3, 41.2, 40, 3.5, "MSX1: slot 2 card ($7FB8..), 512 B sectors", "m_z80", fs=6.0)
    box(ax, 49, 46, 18, 14, "WD1793\nread / write sector,\nread address,\nINTRQ, DRQ", "fabric", fs=6.4)
    box(ax, 71, 46, 27, 14, "bvf_fdc: REQ / ACK / DRIVES\nregisters 0x40 0x44 0x48\n168 LUT, 512 B sector buffer\n(window 0x20000, 8 uSRAM)", "fabric", fs=6.2)
    arrow(ax, (43, 53), (49, 53), both=True)
    arrow(ax, (67, 53), (71, 53), both=True)

    group(ax, 1, 3, 98, 33, "Host (the fabric is the client; Linux is the drive)", "host")
    box(ax, 4, 14, 28, 15, "1  interrupt (PLIC 126)\n2  read REQ: kind, drive,\n    track, sector, side", "host", fs=6.3)
    box(ax, 36, 14, 28, 15, "3  diskimg.py: find the sector\nDMK / HDV / raw .DSK /\nCoCo .DSK .JVC (CRC, DAM)", "host", fs=6.3)
    box(ax, 68, 14, 28, 15, "4  fill (or drain) the sector\nbuffer window\n5  write ACK: found, CRC, DAM", "host", fs=6.3)
    arrow(ax, (32, 21.5), (36, 21.5))
    arrow(ax, (64, 21.5), (68, 21.5))
    box(ax, 4, 5, 44, 6, "images in /var/lib/cp300: dirty ones saved every 2 s", "host", fs=6.3)
    box(ax, 52, 5, 44, 6, "FreHD: second interface (C2-C5) + SD folder; IDE for the CP-400", "host", fs=6.0)
    arrow(ax, (78, 46), (78, 29), color="#B03A3A")
    label(ax, 74.5, 38, "request", fs=6, color="#B03A3A", ha="right")
    arrow(ax, (90, 29), (90, 46), color="#2F5FB3")
    label(ax, 93.5, 38, "answer", fs=6, color="#2F5FB3", ha="left")
    save(fig, out("fig12_disk.png"))


# ------------------------------------------------------------------------------------------------------------ 13  picture path
def fig_frames():
    fig, ax = canvas(100, 60)
    box(ax, 2, 44, 24, 11, "CP-300 video\n512 x 192, 1 bit\nvs_n, pxen, ink", "m_z80", fs=6.8)
    box(ax, 2, 31, 24, 11, "CP-400 6847\n256 x 192, 4 bit", "m_6809", fs=6.8)
    box(ax, 2, 18, 24, 11, "MSX1 vdp18, ZX ULA,\nMC-1000 / Alice VDG\ncolour index 0..15", "m_z80", fs=6.8)
    box(ax, 34, 20, 26, 35, "bvf_fb\n\nm4 = 0: 2 buffers\n(12 KB each),\ncounter published at\nthe end of a frame\n\nm4 = 1 (direct): one\nbuffer, 24 KB, the host\nsets HOLD, waits for\nSTATUS b6, reads,\nclears HOLD", "shared", fs=6.6)
    box(ax, 68, 44, 30, 11, "host: read FRAME,\nbulk read, read FRAME\naccept if counter moved < 2", "host", fs=6.5)
    box(ax, 68, 31, 30, 11, "XOR with the client's\nprevious frame, zlib level 1\n(type 3 frame message)", "host", fs=6.5)
    box(ax, 68, 18, 30, 11, "WebSocket -> browser:\nexpand, putImageData,\nCSS 4:3, pixelated", "ext", fs=6.5)
    arrow(ax, (26, 49), (34, 46), both=False)
    arrow(ax, (26, 36), (34, 38))
    arrow(ax, (26, 23), (34, 28))
    arrow(ax, (60, 48), (68, 49), both=True)
    arrow(ax, (83, 44), (83, 42))
    arrow(ax, (83, 31), (83, 29))
    label(ax, 50, 12.5, "CP-300: lock-free. The writer never waits for Linux, the counter before and after the read tells whether it lapped the reader.", fs=6.3, italic=True)
    label(ax, 50, 8.5, "Other machines: one buffer; a frame is not started while HOLD is set, so the host's read is always consistent.", fs=6.3, italic=True)
    label(ax, 50, 3.5, "Measured on the board: CP-300 about 38-40 fps in the page (hardware 60); CP-400 about 12 fps (package 0.6.0)", fs=6.1, italic=True)
    save(fig, out("fig13_frames.png"))


# ------------------------------------------------------------------------------------------------------------ 14  audio + tape
def fig_events():
    fig, ax = canvas(100, 52)
    group(ax, 1, 28, 98, 22, "Audio: fabric -> host, events with timestamps", "shared")
    box(ax, 4, 32, 20, 12, "machine speaker /\nDAC bit changes", "m_z80", fs=6.8)
    box(ax, 30, 32, 22, 12, "bvf_audio\nlevel + 23-bit us stamp\n256-entry FIFO, sticky lost", "shared", fs=6.6)
    box(ax, 58, 32, 18, 12, "daemon pops up to\n128 edges per call", "host", fs=6.6)
    box(ax, 82, 32, 15, 12, "WebAudio:\nplay-head ~60 ms\nahead", "ext", fs=6.6)
    arrow(ax, (24, 38), (30, 38))
    arrow(ax, (52, 38), (58, 38))
    arrow(ax, (76, 38), (82, 38))
    group(ax, 1, 2, 98, 24, "Tape (all machines): host -> fabric and back", "shared")
    box(ax, 4, 6, 20, 14, "host: .tap .cas\n.c10 .wav\npulse durations\n(us, hold bit)", "host", fs=6.5)
    box(ax, 30, 12, 22, 9, "play FIFO 1024 entries", "shared", fs=6.5)
    box(ax, 30, 4, 22, 6.5, "record FIFO 512 entries", "shared", fs=6.5)
    box(ax, 58, 6, 18, 14, "gated by the\nmachine's motor\nline (or FORCE)", "fabric", fs=6.5)
    box(ax, 82, 6, 15, 14, "per machine:\nCP-300 port $FF\nMSX1 PSG R14 b7\nZX port $FE b6", "m_z80", fs=6.0)
    arrow(ax, (24, 15), (30, 16), both=False)
    arrow(ax, (52, 16), (58, 15))
    arrow(ax, (76, 13), (82, 13), both=True)
    arrow(ax, (58, 9), (52, 8), both=False)
    arrow(ax, (30, 7), (24, 9))
    save(fig, out("fig14_events.png"))


# ------------------------------------------------------------------------------------------------------------ 15  delivery
def fig_delivery():
    fig, ax = canvas(100, 46)
    steps = [
        ("stock framework\n(pinned commit,\nHSS, MSS)", "ext"),
        ("make_cape.py\nadds the CP300 cape\nfrom this repo", "fabric"),
        ("Libero SoC\n(~15 min)\nbitstream .spi", "fabric"),
        ("overlay .dtso\n-> mpfs_dtbo.spi\n(dtc in WSL)", "fabric"),
        ("build_package.py\nclean commit,\nreproducible tar.gz", "host"),
    ]
    x = 2
    for i, (t, k) in enumerate(steps):
        box(ax, x, 26, 17, 14, t, k, fs=6.3)
        if i:
            arrow(ax, (x - 2.5, 33), (x, 33))
        x += 19.7
    group(ax, 1, 2, 98, 20, "On the board", "host")
    box(ax, 4, 5, 26, 12, "scp to ~, sha256", "host", fs=6.5)
    box(ax, 35, 5, 29, 12, "sudo ./install.sh\nsoftware always; web layer;\nflash only if gateware differs", "host", fs=6.3)
    box(ax, 69, 5, 28, 12, "identity string\n2025.10-13-g943f37f-<ver>-CP300\nunique per release", "shared", fs=6.1)
    line(ax, [(90.5, 26), (90.5, 23.8), (17, 23.8)])
    arrow(ax, (17, 23.8), (17, 17))
    label(ax, 55, 25.2, "package (tar.gz + sha256)", fs=6.2)
    arrow(ax, (30, 11), (35, 11))
    arrow(ax, (64, 11), (69, 11))
    label(ax, 50, 43, "Every gateware release raises the design version (the identity string) and the package version", fs=6.6, italic=True)
    save(fig, out("fig15_delivery.png"))


ALL2 = [fig_cp400, fig_msx1, fig_zx, fig_alice, fig_softcpu, fig_vram, fig_disk, fig_frames, fig_events, fig_delivery]
