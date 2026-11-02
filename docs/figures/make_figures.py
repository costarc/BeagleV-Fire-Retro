"""Generates the diagrams of the technical paper (PNG, 200 dpi) into this folder.   python make_figures.py [name ...]"""
import os
import sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fig_lib import *   # noqa
import matplotlib.pyplot as plt


def out(name):
    return os.path.join(HERE, name)


# ------------------------------------------------------------------------------------------------------------ 1
def fig_system():
    fig, ax = canvas(100, 62)
    group(ax, 1, 1, 22, 60, "Browser (any client)", "ext")
    box(ax, 3, 42, 18, 13, "canvas\n256 x 192 or\n512 x 192, 4:3", "ext")
    box(ax, 3, 28, 18, 11, "keyboard\ncharacters ->\nmatrix bits", "ext")
    box(ax, 3, 16, 18, 9, "WebAudio\nedge events", "ext")
    box(ax, 3, 4, 18, 9, "drag and drop\ndisks, tapes,\nROMs", "ext")

    group(ax, 34, 1, 30, 60, "BeagleV-Fire: Linux (U54)", "host")
    box(ax, 36, 50, 26, 6, "nginx :80  /cp300/ -> :8300", "host", fs=7)
    box(ax, 36, 34, 26, 13, "cp300d.py (asyncio, stdlib)\nHTTP + WebSocket, the pump,\ndisk / tape / SD services", "host", fs=7)
    box(ax, 36, 24, 26, 7, "regs32.so: real lw / sw\n(no byte strobes)", "host", fs=7)
    box(ax, 36, 13, 26, 8, "/dev/uio0 (generic-uio)\nFIC window 0x4100_0000, 1 MB", "host", fs=7)
    box(ax, 36, 3, 26, 7, "alice_emu: the MC6803 in C\n(runs with machine 5)", "m_soft", fs=7)

    group(ax, 75, 1, 24, 60, "PolarFire fabric", "fabric")
    box(ax, 77, 49, 20, 8, "APB3 slave\ntoggle CDC, 50 -> 42 MHz", "fabric", fs=7)
    box(ax, 77, 38, 20, 8, "bvf_regs: registers,\nwindows, machine select", "fabric", fs=7)
    box(ax, 77, 22, 20, 13, "one machine at a time:\nCP-300  CP-400  MSX1\nZX  MC-1000\nAlice (video only)", "m_z80", fs=7)
    box(ax, 77, 11, 20, 8, "shared: block-RAM pool,\nframe, audio, tape, FDC", "shared", fs=7)
    box(ax, 77, 3, 20, 5, "DDR master: ROMs", "shared", fs=7)

    arrow(ax, (23, 49), (34, 40), "frames,\naudio,\nstate", both=True, toff=(0, 5.5), fs=6.4)
    arrow(ax, (23, 33), (34, 37), "keys,\nfiles", both=False, toff=(0, -5.5), fs=6.4)
    arrow(ax, (49, 34), (49, 31))
    arrow(ax, (49, 24), (49, 21))
    arrow(ax, (62, 17), (77, 53), "reads /\nwrites", both=True, toff=(-2, -3), fs=6.4)
    arrow(ax, (77, 41), (62, 19), "irq", color="#B03A3A", toff=(3, 1), fs=6.4)
    arrow(ax, (87, 49), (87, 46), both=True)
    arrow(ax, (87, 38), (87, 35), both=True)
    arrow(ax, (87, 22), (87, 19), both=True)
    arrow(ax, (87, 11), (87, 8), both=True)
    arrow(ax, (62, 6.5), (77, 26), "keys,\nVRAM,\n$BFFF", both=True, toff=(2, -6.5), rad=0.2, color="#B03A3A", fs=6.4)
    save(fig, out("fig01_system.png"))


# ------------------------------------------------------------------------------------------------------------ 2
def fig_fabric():
    fig, ax = canvas(100, 72)
    group(ax, 1, 40, 22, 30, "PCLK domain, 50 MHz", "host")
    box(ax, 3, 55, 18, 10, "APB3 slave\npsel, penable,\npready, prdata", "host")
    box(ax, 3, 43, 18, 9, "toggle handshake\n(one access in flight)", "host")
    group(ax, 26, 3, 73, 67, "Core domain, 42 MHz (PLL from PCLK)", "fabric")
    box(ax, 28, 52, 20, 14, "bvf_regs\nID 0x43503005\nCTRL (run, machine)\nkeys, STATUS, windows", "fabric")
    box(ax, 51, 52, 22, 14, "machine select\nb9:8,5:4 of CTRL\nrun = 0 holds all", "fabric")

    group(ax, 28, 25, 69, 24, "Machines (only the selected one runs)", "m_z80")
    box(ax, 30, 34, 13, 10, "CP-300\nht1080z\nWD1793/1010", "m_z80", fs=7)
    box(ax, 45, 34, 13, 10, "CP-400\ncpu09 6809\nSAM, 6847", "m_6809", fs=7)
    box(ax, 60, 34, 11, 10, "MSX1\nvdp18, PSG", "m_z80", fs=7)
    box(ax, 73, 34, 11, 10, "ZX 48K\nown ULA", "m_z80", fs=7)
    box(ax, 86, 34, 9, 10, "MC-1000\nVDG", "m_z80", fs=7)
    box(ax, 30, 26.2, 65, 6.4, "ONE Z80 (T80s) shared by CP-300, MSX1, ZX and MC-1000.\nAlice: the 6803 runs on the host; only its video is here.", "shared", fs=6.8)

    group(ax, 28, 5, 69, 18, "Shared services", "shared")
    box(ax, 30, 9, 14, 11, "block-RAM pool\n64 KB RAM, VRAM,\nframe, cart, ROMs", "shared", fs=6.6)
    box(ax, 46, 9, 12, 11, "bvf_fb\nframe capture\n2 modes", "shared", fs=6.6)
    box(ax, 60, 9, 10, 11, "audio FIFO\n+ tape\nplay / rec", "shared", fs=6.6)
    box(ax, 72, 9, 11, 11, "sector\nservice\nWD1793 x3", "shared", fs=6.6)
    box(ax, 85, 9, 10, 11, "DDR (FIC0)\nROMs +\nprobe", "shared", fs=6.6)

    arrow(ax, (12, 55), (12, 52), both=True)
    arrow(ax, (21, 47.5), (28, 58), both=True)
    arrow(ax, (48, 59), (51, 59))
    arrow(ax, (62, 52), (62, 49), "select", toff=(5, 0))
    arrow(ax, (37, 26), (37, 20), both=True)
    arrow(ax, (52, 26), (52, 20), both=True)
    arrow(ax, (65, 26), (65, 20), both=True)
    arrow(ax, (77, 26), (77, 20), both=True)
    arrow(ax, (90, 26), (90, 20), both=True)
    label(ax, 12, 36, "irq -> INT[0]\n(MSS_INT_F2M[8])", fs=6.8, color="#B03A3A")
    save(fig, out("fig02_fabric.png"))


# ------------------------------------------------------------------------------------------------------------ 3
def fig_lut():
    rows = [
        ("0.3.0  CP-300 + IO controller (Pocket firmware)", 19000, "#7FA6D6", "~19K (78 %), 76 LSRAM"),
        ("4304  IO controller removed", 9226, "#7FA6D6", "9.2K (40 %), 64 LSRAM"),
        ("4307  + CP-400 (6809)", 13737, "#B38FD6", "13.7K (60 %), 72 LSRAM"),
        ("4308  + MiniIDE", 14476, "#B38FD6", "14.5K (63 %), 79 LSRAM"),
        ("4310  + DDR probe", 16036, "#E0A94A", "16.0K (70 %)"),
        ("4313  CP-300 + MSX2 (own Z80)", 19985, "#E07A7A", "20.0K (87 %) after P&R, 76 LSRAM"),
        ("all three: CP-300 + CP-400 + MSX2", 24702, "#C0392B", "24.7K, 87 LSRAM: does not fit"),
        ("4316  trial: shared Z80, MSX1 + ZX", 19500, "#6FBF9F", "19.5K (85 %), 76 LSRAM"),
        ("4320  six machines", 20734, "#6FBF9F", "20.7K (90 %), 77 LSRAM"),
        ("4322  + tape, MSX1 disk", 21432, "#6FBF9F", "21.4K (93 %), 80 LSRAM"),
        ("4323-4328  + CP-400 floppy, MSX disk, fixes", 21659, "#6FBF9F", "21.7K (94 %)"),
    ]
    fig, ax = plt.subplots(figsize=(6.8, 4.3), dpi=200)
    y = list(range(len(rows)))[::-1]
    for yy, (n, v, c, note) in zip(y, rows):
        ax.barh(yy, v, color=c, ec="#333333", lw=0.6, height=0.68)
        ax.text(v + 250, yy, note, va="center", fontsize=6.6)
    ax.axvline(22956, color="#C0392B", lw=1.2, ls="--")
    ax.text(23200, len(rows) - 0.45, "chip: 22,956", color="#C0392B", fontsize=6.8, ha="left", va="bottom")
    ax.set_yticks(y)
    ax.set_yticklabels([r[0] for r in rows], fontsize=6.8)
    ax.set_xlim(0, 36500)
    ax.set_ylim(-0.7, len(rows) + 0.2)
    ax.set_xlabel("4-input LUTs, as recorded when each gateware was built", fontsize=6.6)
    ax.tick_params(axis="x", labelsize=6.5)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    save(fig, out("fig03_luts.png"))


# ------------------------------------------------------------------------------------------------------------ 4
def fig_sharedz80():
    fig, ax = canvas(100, 58)
    box(ax, 37, 22, 26, 14, "T80s: one Z80\nclock enable and bus\nare muxed to the\nselected machine", "shared", bold=True, fs=7.5)
    box(ax, 2, 40, 29, 16, "CP-300 (ht1080z_bvf)\nTRS-80 Model III clone:\nvideo, keyboard, WD1793/1010,\nRAM in the pool", "m_z80", fs=7)
    box(ax, 69, 40, 29, 16, "MSX1 (bvf_msx1)\nslots, PPI, vdp18 (TMS9918A),\nPSG, ROMs in DDR + cache\n3.58 MHz = ena21 / 6", "m_z80", fs=7)
    box(ax, 2, 4, 29, 16, "ZX Spectrum 48K (bvf_zx)\nown ULA, 3.5 MHz = clk / 12\nRAM and ROM in the pool\n(ROM = lower 16 KB, read-only)", "m_z80", fs=7)
    box(ax, 69, 4, 29, 16, "MC-1000 (bvf_mc1000)\nTrucco's MC6847 VDG, PSG,\nROM $C000-$FFFF in the pool,\nVRAM in the pool's VRAM port", "m_z80", fs=7)
    arrow(ax, (31, 46), (37, 33), both=True)
    arrow(ax, (69, 46), (63, 33), both=True)
    arrow(ax, (31, 14), (37, 25), both=True)
    arrow(ax, (69, 14), (63, 25), both=True)
    box(ax, 37, 44, 26, 12, "Not on the shared Z80\nCP-400: 6809 (cpu09) + SAM\nAlice: MC6803 emulated\non the host", "m_6809", fs=6.8)
    label(ax, 50, 14, "to the machine: address, data out,\n/MREQ /IORQ /RD /WR /M1 /RFSH\nfrom the machine: data in, /INT,\nreset, clock enable", fs=6.3, color="#444444")
    label(ax, 50, 1.8, "T80s costs 2.3-2.6K LUTs: four copies would not fit, and only one machine runs at a time.", fs=6.5, italic=True)
    save(fig, out("fig04_shared_z80.png"))


# ------------------------------------------------------------------------------------------------------------ 5
def fig_pool():
    fig, ax = canvas(100, 72)
    label(ax, 50, 69.5, "bvf_pool: 56 block RAMs (LSRAM, 2K x 10) used by whichever machine runs", fs=8, bold=True)
    xs = [1, 12, 35, 58, 75]
    ws = [10, 22, 22, 16, 24]
    heads = ["", "64 KB RAM\n(32 blocks)", "frame buffer\n(12 blocks)", "cartridge ROM\nblocks (4)", "CP-400 ROM blocks (8)\n= VRAM when mx = 1"]
    for j in range(1, 5):
        box(ax, xs[j], 57, ws[j], 9, heads[j], "shared", fs=6.8, bold=True)
    rows = [
        ("CP-300", "64 KB Z80 RAM", "512 x 192 x 1 bit,\n2 buffers", "-", "-"),
        ("CP-400", "64 KB (SAM)", "256 x 192 x 4 bit,\n1 buffer + hold", "DOS cartridge\nROM (optional)", "Color + Extended\nBASIC, 8 KB each"),
        ("MSX1", "64 KB RAM\n(slot 3)", "colour-index\nframe", "ROM read cache\n1024 x 8 bytes", "VRAM 16 KB\n(vdp18)"),
        ("ZX 48K", "48 KB RAM +\n16 KB ROM", "colour-index\nframe", "-", "-"),
        ("MC-1000", "RAM $0000-$BFFF\nROM $C000-$FFFF", "colour-index\nframe", "-", "VRAM 8 KB"),
        ("Alice", "-", "colour-index\nframe", "-", "VRAM 6 KB, filled\nby the host"),
    ]
    h = 7.2
    for i, r in enumerate(rows):
        y = 56 - (i + 1) * (h + 1.0)
        kind = "m_6809" if r[0] == "CP-400" else ("m_soft" if r[0] == "Alice" else "m_z80")
        box(ax, xs[0], y, ws[0], h, r[0], kind, fs=7, bold=True)
        for j in range(1, 5):
            txt = r[j]
            if txt == "-":
                box(ax, xs[j], y, ws[j], h, "unused", "none", fs=6.3, color="#999999", ls=":")
            else:
                box(ax, xs[j], y, ws[j], h, txt, kind, fs=6.3)
    label(ax, 50, 1.2, "Only one machine runs, so the same blocks serve all of them.", fs=6.6, italic=True)
    save(fig, out("fig05_pool.png"))


ALL = [fig_system, fig_fabric, fig_lut, fig_sharedz80, fig_pool]

if __name__ == "__main__":
    try:
        from make_figures2 import ALL2
        ALL = ALL + ALL2
    except ImportError:
        pass
    want = sys.argv[1:]
    for f in ALL:
        if not want or f.__name__ in want:
            f()
    print("done")
