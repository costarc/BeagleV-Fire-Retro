#!/usr/bin/env python3
"""cp300d: the Linux side of the CP-300 on the BeagleV-Fire.

    python3 cp300d.py --uio /dev/uio0                  real board (the FIC window of the gateware)
    python3 cp300d.py --mem 0x60000000                 real board through /dev/mem
    python3 cp300d.py --sim                            no hardware: a simulated register file, for the web page

Serves the web page (web/), a WebSocket with the picture, the keys and the audio, and a few HTTP calls to
mount disks and load the ROMs. Standard library only (Debian's python3 is enough).

    GET  /                       the page
    GET  /ws                     WebSocket: server -> browser  0x01 frame, 0x02 audio, text = JSON state
                                              browser -> server  text JSON {"keys":"<16 hex digits>"} or {"ctrl":{...}}
    GET  /api/state              JSON state
    GET  /api/debug              registers and bus timing (bring-up)
    PUT  /api/disk/<0-3>?name=X  body = disk image (DMK, JV1, JV3 or HFE: converted to DMK); mounts it
    GET  /api/disk/<0-3>         download the (possibly modified) DMK
    DELETE /api/disk/<0-3>       eject
    PUT  /api/hd/<0-1>?name=X    body = FreeHD hard disk image (HDV: xtrs / TRS32 / FreHD format); mounts it
    GET  /api/hd/<0-1>           download the (possibly modified) HDV
    DELETE /api/hd/<0-1>         eject
    PUT  /api/rom/system         body = 16384 bytes;   PUT /api/rom/chargen   body = 2048 bytes
    POST /api/ctrl               JSON {"run":1,"reset":1,"turbo":0,"wp":0}

The register map is in rtl/bvf_regs.v.
"""
import argparse
import array
import asyncio
import atexit
import base64
import hashlib
import json
import mmap
import os
import signal
import struct
import sys
import time
import zlib
try:
    import fcntl                              # Linux (the daemon's home); the tests on a PC do without
except ImportError:
    fcntl = None
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
for p in (os.path.join(HERE, "..", "..", "..", "tools"), os.path.join(HERE, "..", "tools"), HERE):   # installed: /opt/cp300/tools; repository: ../tools
    if os.path.exists(os.path.join(p, "dsk2dmk.py")):
        sys.path.insert(0, p)
if HERE not in sys.path:
    sys.path.insert(0, HERE)
try:
    import dsk2dmk
except ImportError:
    dsk2dmk = None
from diskimg import Dmk, Hdv, RawDsk, DMK_FOUND     # noqa: E402  (next to this file)
from frehd import Frehd                     # noqa: E402
import tape as tapefmt                      # noqa: E402  (next to this file)

# register offsets (rtl/bvf_regs.v)
R_ID, R_CTRL, R_STATUS, R_KEYS_LO, R_KEYS_HI, R_FRAME, R_AUDIO, R_AUDIO_HEAD = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C
R_KEYS2 = 0x20                                # MSX keyboard matrix rows 8..10 (bits 64..87)
R_REQ, R_ACK, R_DRIVES = 0x40, 0x44, 0x48     # the sector service of the floppy / hard disk controllers (bvf_fdc.v)
HD_SLOT = 6                                   # disks[] index of hard disk 0; the floppy drives are 0-3
W_ROM, W_SEC, W_FRAME, W_IDE, W_FRH = 0x10000, 0x20000, 0x30000, 0x40000, 0x50000
R_FRH_REQ, R_FRH_ACK = 0x98, 0x9C             # the FreHD command interface (bvf_frehd.v), buffer window W_FRH (word n = byte n)
R_IDE_REQ, R_IDE_LBA, R_IDE_ACK, R_IDE_CFG = 0x50, 0x54, 0x58, 0x5C   # the CP-400's hard disk (bvf_ide.v)
ID_VALUE = 0x43503005                         # 0x43503002: one machine (CP-300); 0x43503003: CTRL has the machine and frame hold bits; 0x43503004: the Alice (A0 register, 0x60000 window)

ST_PENDING, ST_REQ_WR, ST_AUD_LOST, ST_LATEST, ST_COPY, ST_IDE, ST_FRH = 4, 8, 32, 64, 128, 16, 2
# REQ bits
RQ_RD, RQ_WR, RQ_RA, RQ_SIDE, RQ_DAM, RQ_HD = 1, 2, 4, 8, 64, 128
FRAME_WORDS = 3072          # 512 x 192 / 32
FRAME_BYTES = FRAME_WORDS * 4
SYS_ROM, CHARGEN = 16384, 2048
# machines (CTRL b5:4); the CP-400 (CoCo 2) has Color BASIC and Extended BASIC, 8 KB each, and a 256 x 192 picture at 4 bits
MACHINES = {"cp300": 0, "cp400": 1, "msx1": 2, "zx": 3, "mc1000": 4, "alice": 5}
MACH_NAMES = ("cp300", "cp400", "msx1", "zx", "mc1000", "alice")
# the MSX1 (rtl/bvf_msx1.v): its ROMs live in DDR ($C800_0000, the reserved 32 MB), written through the DDR probe's registers
# (rtl/bvf_ddr.v): the BIOS + BASIC (32 KB, slot 0 pages 0-1), a 16 KB ROM in slot 0 page 2 (C-BIOS: its logo; optional),
# a cartridge (slot 1, $4000-$BFFF, up to 32 KB; optional). Its RAM and VRAM are on chip; the picture comes as the CP-400's.
DDR_BASE, MSX_BIOS, MSX_P2, MSX_CART = 0xC8000000, 0x620000, 0x63C000, 0x640000
MSX_BIOS_SIZE, MSX_P2_SIZE, MSX_CART_MAX = 32768, 16384, 32768
# the MSX1's disk interface (slot 2, page 1): its 16 KB disk ROM in the DDR window; the WD1793 is the CP-300's, the drives 0 and 1 are
# the images in disks[4] and disks[5] (512 byte sectors, diskimg.RawDsk)
MSX_DISK, MSX_DISK_SIZE = 0x648000, 16384
MSX_DRIVE0 = 4
# the CP-400's floppy controller card (rtl/bvf_cocofdc.v): four drives of 256 byte sector images (.DSK, .JVC), slots 8-11
COCO_DRIVE0 = 8
NSLOTS = 12
# the ZX Spectrum 48K (rtl/bvf_zx.v): its 16 KB ROM goes into the lower 16 KB of the machine's RAM through the ROM load window;
# the MC-1000 (rtl/bvf_mc1000.v): its 16 KB ROM into the upper 16 KB the same way
ZX_ROM = MC_ROM = 16384
# the Matra Alice (rtl/bvf_mc1000.v with alice = 1): the 6803 is emulated by the alice_emu process (alice/emu/alice_emu.c), which
# writes the video RAM and the $BFFF latch into the gateware and reads the keys; the daemon starts and stops it with the machine.
# Its ROM is the 8 KB BASIC of the original Alice / MC-10 (MC6847), at $E000.
ALICE_ROM = 8192
# the cassette recorder (rtl/bvf_tape.v)
R_TAPE_CTRL, R_TAPE_PLAY, R_TAPE_RECN, R_TAPE_RECD = 0xA4, 0xA8, 0xAC, 0xB0
R_DEBUG = 0xB4                               # the CP-400's 6809 address and the floppy card (rtl/bvf_regs.v)
R_PCTRL, R_PALO, R_PAHI, R_PWLO, R_PWHI, R_PCNT, R_PRES = 0x60, 0x64, 0x68, 0x6C, 0x70, 0x74, 0x90
CTRL_MACH_SHIFT, CTRL_MACH_HI, CTRL_HOLD = 4, 8, 0x40     # machine: b5:4 low bits, b9:8 high bits


def ctrl_machine(ctrl):
    """The machine number in a CTRL value."""
    return ((ctrl >> CTRL_MACH_SHIFT) & 3) | (((ctrl >> CTRL_MACH_HI) & 3) << 2)


COCO_ROM = 8192                                # also the cartridge (the MiniIDE DOS) at $C000
IDE_ERR_IDNF = 0x10
IDE_ERR_ABRT = 0x04
COCO_FRAME_BYTES = 256 * 192 // 2


# ---------------------------------------------------------------- register access
class MemRegs:
    """The FIC window of the gateware, through /dev/uioN or /dev/mem.

    The window is a 32 bit APB bus without byte strobes, so every access must be a real 32 bit load or store. Python's
    struct / memcpy use byte stores on this board (the word ends up as one byte repeated), so the accesses are done by
    regs32.c, compiled with gcc on first use."""
    def __init__(self, path, base=0, size=0x100000):
        import ctypes
        self.uio = base == 0 and "/uio" in path
        self.emu_args = ["--uio", path] if self.uio else ["--mem", hex(base)]    # how alice_emu maps the same window
        self.fd = os.open(path, os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        self.base = ctypes.addressof(ctypes.c_char.from_buffer(self.mm))
        self.lib = self._load_lib(ctypes)
        self.ct = ctypes

    @staticmethod
    def _load_lib(ctypes):
        import subprocess
        import tempfile
        src = os.path.join(HERE, "regs32.c")
        out = os.path.join(HERE, "regs32.so")
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
            try:
                subprocess.check_call(["gcc", "-O2", "-shared", "-fPIC", "-o", out, src])
            except (OSError, subprocess.CalledProcessError):       # e.g. the install folder is read only
                out = os.path.join(tempfile.gettempdir(), "cp300_regs32.so")
                subprocess.check_call(["gcc", "-O2", "-shared", "-fPIC", "-o", out, src])
        lib = ctypes.CDLL(out)
        lib.rd32.restype = ctypes.c_uint32
        lib.rd32.argtypes = [ctypes.c_size_t]
        lib.wr32.restype = None
        lib.wr32.argtypes = [ctypes.c_size_t, ctypes.c_uint32]
        lib.rdblk.restype = None
        lib.rdblk.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        lib.wrblk.restype = None
        lib.wrblk.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        return lib

    def read32(self, off):
        return self.lib.rd32(self.base + off)

    def write32(self, off, val):
        self.lib.wr32(self.base + off, val & 0xFFFFFFFF)

    def read_block(self, off, n):
        buf = bytearray(n)
        self.lib.rdblk(self.base + off, (self.ct.c_char * n).from_buffer(buf), n // 4)
        return bytes(buf)

    def write_block(self, off, data):
        buf = bytes(data)
        self.lib.wrblk(self.base + off, self.ct.c_char_p(buf), len(buf) // 4)

    # The disk request interrupt (UIO): uio_pdrv_genirq masks it each time it fires; writing 1 to the device unmasks
    # it, reading it returns the interrupt count. Without an interrupt in the overlay (package 0.2.0) both fail with
    # EIO and the daemon only polls.
    def irq_fd(self):
        """The file descriptor to wait on for the interrupt (unmasked), or None if there is none."""
        if not self.uio:
            return None
        try:
            self.irq_unmask()
        except OSError:
            return None
        return self.fd

    def irq_unmask(self):
        os.write(self.fd, struct.pack("=I", 1))

    def irq_read(self):
        return struct.unpack("=I", os.read(self.fd, 4))[0]


class SimRegs:
    """A register file that behaves like the gateware as far as the daemon can tell: for the web page and
    for testing the daemon without a board. The picture shows a grid of the keys pressed."""
    def __init__(self):
        self.t0 = time.monotonic()
        self.ctrl = 0
        self.keys = 0
        self.rom = bytearray(SYS_ROM + CHARGEN)
        # the controllers' service port (bvf_fdc.v): a pending request (the REQ word), the 512-byte sector buffer,
        # ACK and the drive flags; every answered request goes into `log` as (REQ, result bits, buffer bytes)
        self.req = 0
        self.ack = 0
        self.res = 0
        self.drives = 0
        self.buf = bytearray(512)
        self.served = 0
        self.audio = []
        self.log = []
        self.ide_req = 0           # the CP-400's hard disk: a pending request (REQ word), its LBA, the 512 byte window
        self.ide_lba = 0
        self.ide_cfg = 0
        self.ide_err = 0
        self.ide_buf = bytearray(512)
        self.ide_log = []          # (REQ, LBA, error code, window bytes) of every answered request
        self.frh_req = 0           # the FreHD command interface: a pending command (REQ word), its 256 byte buffer
        self.frh_buf = bytearray(256)
        self.frh_ack = 0
        self.frh_log = []          # (REQ, ACK word, buffer bytes) of every answered command
        self.tape_ctl = 0          # the cassette recorder: play FIFO (entries pushed, drained at 300 per CTRL read), record FIFO
        self.tape_in = []
        self.tape_played = []
        self.tape_rec = []

    def request(self, req):
        """The controller asks for a sector: REQ word (see bvf_regs.v). For a write, put the data in buf first."""
        self.req = req

    def _frame_no(self):
        return int((time.monotonic() - self.t0) * 60) & 0xFFFF

    def _picture(self):
        n = self._frame_no()
        px = bytearray(FRAME_BYTES)
        def setpx(x, y):
            px[(y * 512 + x) // 8] |= 1 << (x % 8)
        for x in range(512):
            setpx(x, 0); setpx(x, 191)
        for y in range(192):
            setpx(0, y); setpx(511, y)
        for k in range(64):
            if (self.keys >> k) & 1:
                cx, cy = (k % 8) * 56 + 40, (k // 8) * 20 + 16
                for y in range(cy, cy + 14):
                    for x in range(cx, cx + 48):
                        setpx(x, y)
        x = n % 500 + 6
        for y in range(180, 186):
            setpx(x, y)
        return bytes(px)

    def _picture4(self):
        """The CP-400 picture of the simulation: a frame of colour 5 (white) and one block of colour (1 + key % 10) per key down."""
        px = bytearray(COCO_FRAME_BYTES)
        def setpx(x, y, c):
            i = y * 128 + x // 2
            px[i] = (px[i] & (0xF0 if x % 2 else 0x0F)) | (c << (4 if x % 2 else 0))
        for x in range(256):
            setpx(x, 0, 5); setpx(x, 191, 5)
        for y in range(192):
            setpx(0, y, 5); setpx(255, y, 5)
        for k in range(64):
            if (self.keys >> k) & 1:
                cx, cy = (k % 8) * 28 + 20, (k // 8) * 20 + 16
                for y in range(cy, cy + 14):
                    for x in range(cx, cx + 24):
                        setpx(x, y, 1 + k % 10)
        return bytes(px)

    def read32(self, off):
        if off == R_ID: return ID_VALUE
        if off == R_CTRL: return self.ctrl
        if off == R_STATUS:
            pend = bool(self.req & 7) and not self.ack
            return (ST_PENDING if pend else 0) | (ST_REQ_WR if self.req & RQ_WR else 0) | ST_LATEST | (ST_IDE if self.ide_req else 0) | (ST_FRH if self.frh_req else 0)
        if off == R_TAPE_CTRL:
            res = self.tape_in[:300]                     # the gateware plays 300 entries between two reads
            self.tape_played += res
            del self.tape_in[:300]
            return ((1024 - len(self.tape_in)) << 16) | (0x200 if not self.tape_in else 0) | (0x100 if res else 0) | (self.tape_ctl & 0x15)
        if off == R_TAPE_RECN: return len(self.tape_rec)
        if off == R_TAPE_RECD: return self.tape_rec[0] if self.tape_rec else 0
        if off == R_KEYS_LO: return self.keys & 0xFFFFFFFF
        if off == R_KEYS_HI: return self.keys >> 32
        if off == R_FRAME: return self._frame_no()
        if off == R_AUDIO: return len(self.audio)
        if off == R_AUDIO_HEAD: return self.audio[0] if self.audio else 0
        if off == R_REQ: return self.req
        if off == R_ACK: return self.res << 8 | self.ack
        if off == R_DRIVES: return self.drives
        if off == R_IDE_REQ: return self.ide_req
        if off == R_IDE_LBA: return self.ide_lba
        if off == R_IDE_ACK: return self.ide_err << 8 | (1 if self.ide_req else 0)
        if off == R_IDE_CFG: return self.ide_cfg
        if off == R_FRH_REQ: return self.frh_req
        if off == R_PRES: return 1                    # the DDR probe: every access done at once, no error (the DDR is not modelled)
        if W_FRH <= off < W_FRH + 1024: return self.frh_buf[(off - W_FRH) // 4]
        if W_IDE <= off < W_IDE + 512: return struct.unpack_from("<I", self.ide_buf, off - W_IDE)[0]
        if W_SEC <= off < W_SEC + 512: return struct.unpack_from("<I", self.buf, off - W_SEC)[0]
        return 0

    def write32(self, off, val):
        if off == R_CTRL:
            if (val & 1) and not (self.ctrl & 1) and (self.drives & 1) and ctrl_machine(val) == 0:
                self.req = RQ_RD                          # a boot: track 0, sector 0 of drive 0
            if not val & 1:
                self.req = self.ack = 0                   # the core and the handshake held in reset
            self.ctrl = val & ~0x82
        elif off == R_TAPE_CTRL:
            self.tape_ctl = val
            if val & 2: self.tape_in = []
            if val & 8: self.tape_rec = []
        elif off == R_TAPE_PLAY:
            self.tape_in.append(val)
        elif off == R_TAPE_RECD and self.tape_rec:
            self.tape_rec.pop(0)
        elif off == R_KEYS_LO:
            self._key_edge(val)
        elif off == R_KEYS_HI:
            self.keys = (self.keys & 0xFFFFFFFF) | (val << 32)
        elif off == R_AUDIO_HEAD and self.audio:
            self.audio.pop(0)
        elif off == R_ACK:
            self.res = (val >> 8) & 7
            if (val & 1) and not self.ack:
                self.ack, self.served = 1, self.req       # the request drops once ack is up
                self.req = 0
            elif not (val & 1) and self.ack:
                self.ack = 0
                self.log.append((self.served, self.res, bytes(self.buf)))
        elif off == R_DRIVES:
            self.drives = val & 0xFFF
        elif off == R_IDE_CFG:
            self.ide_cfg = val & 15
        elif off == R_FRH_ACK:
            if self.frh_req:
                self.frh_log.append((self.frh_req, val, bytes(self.frh_buf)))
                self.frh_ack = val
                self.frh_req = 0
        elif W_FRH <= off < W_FRH + 1024:
            self.frh_buf[(off - W_FRH) // 4] = val & 255
        elif off == R_IDE_ACK:
            if (val & 1) and self.ide_req:
                self.ide_err = (val >> 8) & 0xFF
                self.ide_log.append((self.ide_req, self.ide_lba, self.ide_err, bytes(self.ide_buf)))
                self.ide_req = 0
        elif W_IDE <= off < W_IDE + 512:
            struct.pack_into("<I", self.ide_buf, off - W_IDE, val)
        elif W_ROM <= off < W_ROM + 0x10000:
            pass
        elif W_SEC <= off < W_SEC + 512 and self.ack:     # the buffer is the host's only under ack
            struct.pack_into("<I", self.buf, off - W_SEC, val)

    def _key_edge(self, lo):
        if lo & ~(self.keys & 0xFFFFFFFF):               # a key went down: click
            t = int((time.monotonic() - self.t0) * 1e6) & 0x7FFFFF
            self.audio += [(0x11 << 23) | t, (0x10 << 23) | ((t + 800) & 0x7FFFFF)]
        self.keys = (self.keys & ~0xFFFFFFFF) | lo

    def read_block(self, off, n):
        if W_FRH <= off < W_FRH + 1024:
            out = bytearray()
            for i in range(n // 4):
                out += struct.pack("<I", self.frh_buf[(off - W_FRH) // 4 + i])
            return bytes(out)
        if off == W_FRAME:
            if ctrl_machine(self.ctrl) == 1:
                return self._picture4()[:n]
            return self._picture()[:n]
        if W_SEC <= off < W_SEC + 512:
            return bytes(self.buf[off - W_SEC:off - W_SEC + n])
        if W_IDE <= off < W_IDE + 512:
            return bytes(self.ide_buf[off - W_IDE:off - W_IDE + n])
        return b"\0" * n

    def write_block(self, off, data):
        if W_FRH <= off < W_FRH + 1024:
            for i in range(0, len(data) - 3, 4):
                self.frh_buf[(off - W_FRH + i) // 4] = data[i]
        elif W_IDE <= off < W_IDE + 512:
            self.ide_buf[off - W_IDE:off - W_IDE + len(data)] = data
        elif W_SEC <= off < W_SEC + 512:
            if self.ack:
                self.buf[off - W_SEC:off - W_SEC + len(data)] = data
        elif W_ROM <= off < W_ROM + 0x10000:
            self.rom[off - W_ROM:off - W_ROM + len(data)] = data
        else:                                           # registers: word by word, as the bus does
            for i in range(0, len(data) - 3, 4):
                self.write32(off + i, struct.unpack_from("<I", data, i)[0])


# ---------------------------------------------------------------- the device
def sector_words(b):
    """The sector as the window must hold it for the DOS's read loop: word k has the high byte b[2k+1] and, as its LOW byte, the
    low byte of the word BEFORE it, b[2k-2]. Found by running the DOS in simulation on the real disk data (the simulation prints the
    same scrambled directory as the board): HDB-DOS stores the pair (value of $FF50 read in iteration j+1, value of $FF58 read in
    iteration j), which is in order only when the low byte lags one word. (The original IDE has a one access delay in its data
    path; this is that effect for a sector read as a whole.) Word 0's low byte is never stored."""
    out = bytearray(len(b))
    for k in range(len(b) // 2):
        out[2 * k] = b[2 * k - 2] if k else b[0]
        out[2 * k + 1] = b[2 * k + 1]
    return bytes(out)


class IdeDisk:
    """The CP-400's hard disk: a raw image of 512 byte sectors in a file (LBA), read and written in place."""
    def __init__(self, path):
        self.path = path
        self.f = open(path, "r+b")
        self.sectors = os.fstat(self.f.fileno()).st_size // 512

    def read(self, lba):
        if lba >= self.sectors:
            return None
        self.f.seek(lba * 512)
        d = self.f.read(512)
        return d + b"\0" * (512 - len(d))

    def write(self, lba, data):
        if lba >= self.sectors:
            return False
        self.f.seek(lba * 512)
        self.f.write(bytes(data))
        self.f.flush()
        return True

    def identify(self):
        """The ATA IDENTIFY DEVICE sector: a fixed disk with LBA, capacity of the image, CHS made up from it."""
        w = [0] * 256
        heads, spt = 16, 63
        cyl = max(1, min(16383, self.sectors // (heads * spt)))
        w[0], w[1], w[3], w[6] = 0x0040, cyl, heads, spt
        def text(first, count, t):
            t = t.ljust(count * 2)[:count * 2].encode("ascii")
            for i in range(count):
                w[first + i] = (t[2 * i] << 8) | t[2 * i + 1]
        text(10, 10, "BVF0001")
        text(23, 4, "1.0")
        text(27, 20, "BeagleV-Fire IDE disk")
        w[47], w[49], w[53] = 1, 0x0200, 1
        w[54], w[55], w[56] = cyl, heads, spt
        n = min(self.sectors, 0x0FFFFFFF)
        w[57], w[58] = (cyl * heads * spt) & 0xFFFF, (cyl * heads * spt) >> 16
        w[60], w[61] = n & 0xFFFF, n >> 16
        return struct.pack("<256H", *w)

    def close(self):
        self.f.close()


# the Alice's recorder lives in alice_emu (alice/emu/alice_tape.h): the same entries on its stdin, words with 0x7000000n as commands
EMU_CMD_PLAY, EMU_CMD_STOP, EMU_CMD_FLUSH, EMU_CMD_REC, EMU_CMD_RECOFF = 0x70000001, 0x70000002, 0x70000003, 0x70000004, 0x70000005


class TapeDeck:
    """The cassette recorder of the gateware as a deck: a tape (pulse entries, see tape.py) that plays through the machine's tape
    input while PLAY is on and the machine's motor is on, and a recording of the machine's tape output. The gateware's FIFO holds a
    few hundred ms: service() tops it up every few tens of ms."""

    def __init__(self, dev):
        self.dev = dev
        self.name = ""
        self.words = array.array("I")
        self.pos = 0
        self.play = False
        self.rec = False
        self.force = False
        self.records = []
        self.status = 0
        self.us = 0
        self.emu_free = 0             # the Alice: what alice_emu says it can take, and whether it is still playing an entry
        self.emu_active = False
        self.emu_buf = b""

    def _emu(self):
        d = self.dev
        return d.emu if d.machine == 5 and d.emu is not None and d.emu.poll() is None else None

    def _emu_send(self, e, words):
        try:
            e.stdin.write(array.array("I", words).tobytes())
            e.stdin.flush()
        except (OSError, ValueError):
            pass

    def _emu_poll(self, e):
        """The lines of alice_emu: F <free> <active>, R <level> <microseconds> (a recorded change)."""
        try:
            data = os.read(e.stdout.fileno(), 65536)
        except (BlockingIOError, OSError):
            return
        self.emu_buf += data
        *lines, self.emu_buf = self.emu_buf.split(b"\n")
        for ln in lines:
            f = ln.split()
            if len(f) == 3 and f[0] == b"F":
                self.emu_free, self.emu_active = int(f[1]), bool(int(f[2]))
            elif len(f) == 3 and f[0] == b"R" and self.rec:
                self.records.append((int(f[1]), int(f[2])))

    def _ctl(self, flush_p=False, flush_r=False, setlevel=None, clear=False):
        e = self._emu()
        if e is not None:
            w = [EMU_CMD_FLUSH] if flush_p else []
            w += [EMU_CMD_PLAY if self.play else EMU_CMD_STOP, EMU_CMD_REC if self.rec else EMU_CMD_RECOFF]
            if flush_p:
                self.emu_free = 0
            self._emu_send(e, w)
            return
        v = (1 if self.play else 0) | (2 if flush_p else 0) | (4 if self.rec else 0) | (8 if flush_r else 0) | (16 if self.force else 0)
        if setlevel is not None:
            v |= 0x40 | (0x20 if setlevel else 0)
        if clear:
            v |= 0x80
        self.dev.r.write32(R_TAPE_CTRL, v)

    def load(self, name, words):
        self.play = False
        self.name, self.words = name, words
        self.us = tapefmt.duration_us(words)
        self.rewind()

    def eject(self):
        self.play = False
        self.name, self.words, self.pos, self.us = "", array.array("I"), 0, 0
        self._ctl(flush_p=True, setlevel=0, clear=True)

    def rewind(self):
        self.play = False
        self.pos = 0
        self._ctl(flush_p=True, setlevel=0, clear=True)

    def command(self, cmd, value=None):
        if cmd == "play":
            if self.pos >= len(self.words):
                self.rewind()
            self.play = len(self.words) > 0
            self._ctl()
        elif cmd == "stop":
            self.play = False
            self._ctl()
        elif cmd == "rewind":
            self.rewind()
        elif cmd == "force":
            self.force = bool(value)
            self._ctl()
        elif cmd == "record":
            self.rec = True
            self.records = []
            self._ctl(flush_r=True, clear=True)
        elif cmd == "stoprec":
            self.rec = False
            self._ctl()
        elif cmd == "clearrec":
            self.records = []
            self._ctl(flush_r=True)
        else:
            raise ValueError("unknown tape command %r" % (cmd,))

    def service(self):
        """Feed the play FIFO, collect the recorded edges. Returns True when something changed that the page shows."""
        e = self._emu()
        if e is not None:                                  # the Alice: the emulator process plays and records
            self._emu_poll(e)
            changed = False
            if self.play:
                n = min(self.emu_free, len(self.words) - self.pos, 400)
                if n > 0:
                    self._emu_send(e, self.words[self.pos:self.pos + n])
                    self.pos += n
                    self.emu_free -= n
                    changed = True
                if self.pos >= len(self.words) and self.emu_free > 0 and not self.emu_active:
                    self.play = False
                    self._ctl()
                    changed = True
            return changed
        if not (self.play or self.rec):
            return False
        r = self.dev.r
        changed = False
        if self.play:
            st = r.read32(R_TAPE_CTRL)
            self.status = st
            free = (st >> 16) & 0x7FF
            n = min(free, len(self.words) - self.pos, 400)
            for i in range(n):
                r.write32(R_TAPE_PLAY, self.words[self.pos + i])
            self.pos += n
            changed = n > 0
            if self.pos >= len(self.words) and (st >> 9) & 1 and not (st >> 8) & 1:
                self.play = False                      # the end of the tape: everything was played
                self._ctl()
                changed = True
        if self.rec:
            n = r.read32(R_TAPE_RECN) & 0x3FF
            for _ in range(min(n, 300)):
                w = r.read32(R_TAPE_RECD)
                r.write32(R_TAPE_RECD, 0)
                self.records.append((w >> 30, w & 0x1FFFFFFF))
            changed = changed or n > 0
        return changed

    def state(self):
        return {"name": self.name, "len": len(self.words), "pos": self.pos, "play": self.play, "rec": self.rec, "force": self.force,
                "us": self.us, "recorded": len(self.records),
                "running": (self.emu_active if self.dev.machine == 5 else bool((self.status >> 8) & 1)) and self.play}


class Cp300:
    def __init__(self, regs, datadir):
        self.r = regs
        self.datadir = datadir
        os.makedirs(datadir, exist_ok=True)
        self.disks = [None] * NSLOTS                       # bytearray of a DMK (0-3) or an HDV (6, 7)
        self.media = [None] * NSLOTS                       # diskimg.Dmk / Hdv over disks[n]: answers the sector requests
        self.names = [""] * NSLOTS
        self.dirty = [False] * NSLOTS
        self.sysrom = None
        self.chargen = None
        self.machine = 0
        self.msx = {"bios": None, "p2": None, "cart": None, "disk": None}        # MSX1 BIOS (32 KB), slot 0 page 2 ROM, cartridge, see roms_ready
        self.zxrom = None                                           # the Spectrum's ROM (16 KB)
        self.mcrom = None                                           # the MC-1000's ROM (16 KB)
        self.alicerom = None                                        # the Alice's ROM (8 KB)
        self.emu = None                                             # the running alice_emu process
        self.coco = {"bas": None, "ext": None, "cart": None}      # CP-400 Color BASIC, Extended BASIC, the cartridge (MiniIDE DOS)
        self.ide = None                               # IdeDisk of /var/lib/cp300/ide0.img
        self.ide_name = ""
        self.sd = Frehd(self._path("sd"), mounter=self.mount_hd, drives=self._hd_info)   # the FreHD's "SD card"
        self.ctrl = {"run": 0, "turbo": 0, "wp": 0}
        self.last_frame = -1
        self.frame_seq = 0
        self.keys = 0
        self.last_disk = 0.0                          # when the last disk request was answered (the picture slows down while the disks are busy)
        self.stats = {"requests": 0, "errors": 0, "frames": 0, "dropped": 0, "irqs": 0,
                      # disk request latency: from the interrupt to the end of the answer (ms): the slowest, how many took over 20 ms, the last slow ones
                      "lat_max_ms": 0.0, "lat_slow": 0, "lat_last_slow": []}
        self.tape = TapeDeck(self)
        if self.r.read32(R_ID) != ID_VALUE:
            raise SystemExit("register window does not answer with the CP-300 ID (0x%08X)" % ID_VALUE)
        self._load_saved()

    # -- saved state
    def _path(self, name):
        return os.path.join(self.datadir, name)

    def _load_saved(self):
        if os.path.exists(self._path("machine")):
            try:
                self.machine = int(open(self._path("machine")).read().strip())
                if self.machine >= len(MACH_NAMES):
                    self.machine = 0
            except ValueError:
                pass
        if os.path.exists(self._path("ide0.img")):
            self.ide = IdeDisk(self._path("ide0.img"))
            self.ide_name = meta0.get("ide", "ide0.img") if (meta0 := self._meta()) else "ide0.img"
        for key, name in (("bas", "cp400bas.rom"), ("ext", "cp400ext.rom"), ("cart", "cp400cart.rom")):
            p = self._path(name)
            if os.path.exists(p):
                data = open(p, "rb").read()
                if len(data) == COCO_ROM:
                    self.coco[key] = data
        for key in ("bios", "p2", "cart", "disk"):
            p = self._path("msx1%s.rom" % key)
            if os.path.exists(p):
                self.msx[key] = open(p, "rb").read()
        if os.path.exists(self._path("zx48.rom")):
            data = open(self._path("zx48.rom"), "rb").read()
            if len(data) == ZX_ROM:
                self.zxrom = data
        if os.path.exists(self._path("mc1000.rom")):
            data = open(self._path("mc1000.rom"), "rb").read()
            if len(data) == MC_ROM:
                self.mcrom = data
        if os.path.exists(self._path("alice.rom")):
            data = open(self._path("alice.rom"), "rb").read()
            if len(data) == ALICE_ROM:
                self.alicerom = data
        for n, key in ((0, "system.rom"), (1, "chargen.rom")):
            p = self._path(key)
            if os.path.exists(p):
                data = open(p, "rb").read()
                if n == 0 and len(data) == SYS_ROM: self.sysrom = data
                if n == 1 and len(data) == CHARGEN: self.chargen = data
        meta = {}
        if os.path.exists(self._path("drives.json")):
            meta = json.load(open(self._path("drives.json")))
        for n in range(NSLOTS):
            p = self._disk_path(n)
            if os.path.exists(p):
                self.disks[n] = bytearray(open(p, "rb").read())
                self.names[n] = meta.get(str(n), os.path.basename(p))
                self._attach(n)

    def _meta(self):
        try:
            return json.load(open(self._path("drives.json")))
        except (OSError, ValueError):
            return {}

    def _disk_path(self, n):
        if COCO_DRIVE0 <= n < COCO_DRIVE0 + 4:
            return self._path("cocodisk%d.dsk" % (n - COCO_DRIVE0))
        if MSX_DRIVE0 <= n < MSX_DRIVE0 + 2:
            return self._path("msxdisk%d.dsk" % (n - MSX_DRIVE0))
        return self._path("drive%d.dmk" % n if n < 4 else "hd%d.hdv" % (n - HD_SLOT))

    def _save_meta(self):
        meta = {str(n): self.names[n] for n in range(NSLOTS)}
        meta["ide"] = self.ide_name
        json.dump(meta, open(self._path("drives.json"), "w"))

    def save_dirty(self):
        for n in range(NSLOTS):
            if self.dirty[n] and self.disks[n] is not None:
                open(self._disk_path(n), "wb").write(self.disks[n])
                self.dirty[n] = False

    # -- ROMs and start
    def roms_ready(self):
        if self.machine == 2:
            return self.msx["bios"] is not None
        if self.machine == 3:
            return self.zxrom is not None
        if self.machine == 4:
            return self.mcrom is not None
        if self.machine == 5:
            return self.alicerom is not None
        if self.machine == 1:
            return self.coco["bas"] is not None and self.coco["ext"] is not None
        return self.sysrom is not None and self.chargen is not None

    def ddr_write(self, off, data):
        """Write bytes (padded to 8) at DDR_BASE + off through the DDR probe (mode 2: one 64 bit write): the host's way into the
        MSX1's ROMs. The machine is held (CTRL.run = 0), so the AXI master belongs to the probe."""
        r = self.r
        data = bytes(data) + b"\xff" * (-len(data) % 8)
        for i in range(0, len(data), 8):
            a = DDR_BASE + off + i
            q = int.from_bytes(data[i:i + 8], "little")
            r.write32(R_PALO, a & 0xFFFFFFFF); r.write32(R_PAHI, a >> 32)
            r.write32(R_PWLO, q & 0xFFFFFFFF); r.write32(R_PWHI, q >> 32)
            r.write32(R_PCNT, 1)
            r.write32(R_PCTRL, 8 | 2)
            t = time.monotonic()
            while True:
                res = r.read32(R_PRES)
                if res & 1 and not res & 2:
                    break
                if time.monotonic() - t > 2:
                    r.write32(R_PCTRL, 0x10); time.sleep(0.01); r.write32(R_PCTRL, 0)
                    raise RuntimeError("the DDR probe did not answer (write at %#x)" % a)

    def load_roms(self):
        # four bytes make a word, first byte in bits 31:24 (rtl/ht1080z): big endian words
        if self.machine == 2:
            # absent ROMs read $FF (the BIOS then finds no cartridge header)
            self.ddr_write(MSX_BIOS, self.msx["bios"][:MSX_BIOS_SIZE])
            self.ddr_write(MSX_P2, (self.msx["p2"] or b"")[:MSX_P2_SIZE].ljust(MSX_P2_SIZE, b"\xff"))
            if self.msx["cart"] is not None:
                self.ddr_write(MSX_CART, self.msx["cart"][:MSX_CART_MAX].ljust(MSX_CART_MAX, b"\xff"))
            if self.msx["disk"] is not None:
                self.ddr_write(MSX_DISK, self.msx["disk"][:MSX_DISK_SIZE].ljust(MSX_DISK_SIZE, b"\xff"))
            return
        if self.machine == 3:
            roms = ((0, self.zxrom),)
        elif self.machine == 4:
            roms = ((0, self.mcrom),)
        elif self.machine == 1:
            # CP-400: Extended BASIC ($8000) at word 0, Color BASIC ($A000) at word 2048
            roms = [(0, self.coco["ext"]), (0x2000, self.coco["bas"])]
            if self.coco["cart"] is not None:
                roms.append((0x4000, self.coco["cart"]))     # words 4096-6143
        else:
            roms = ((0, self.sysrom), (0x4000, self.chargen))
        for base, data in roms:
            words = struct.unpack(">%dI" % (len(data) // 4), data)
            for i, w in enumerate(words):
                self.r.write32(W_ROM + base + 4 * i, w)

    def _attach(self, n):
        """The sector access object of disks[n] (None if the slot is empty)."""
        d = self.disks[n]
        self.media[n] = None if d is None else (Dmk(d) if n < 4 else RawDsk(d) if n < HD_SLOT else Hdv(d) if n < COCO_DRIVE0 else RawDsk(d, 256))

    def _protected(self, n):
        m = self.media[n]
        return bool(self.ctrl["wp"]) or m.readonly

    def publish_drives(self):
        """Tell the controllers which drives hold a usable image and which are write protected (DRIVES).
        The register keeps its value while the core is held, so this goes out before the core is released."""
        v = 0
        for n in range(4):
            src = MSX_DRIVE0 + n if self.machine == 2 else COCO_DRIVE0 + n if self.machine == 1 else n      # the MSX1 and the CP-400 have drives of their own
            m = self.media[src] if src < NSLOTS and (src < HD_SLOT or src >= COCO_DRIVE0 or self.machine == 2) else None
            if m is not None and m.ok and (self.machine != 2 or n < 2):
                v |= 1 << n
                if self._protected(src):
                    v |= 0x10 << n
        for h in range(2):
            m = self.media[HD_SLOT + h]
            if m is not None and m.ok:
                v |= 0x100 << h
                if self._protected(HD_SLOT + h):
                    v |= 0x400 << h
        self.r.write32(R_DRIVES, v)
        self.publish_ide()

    def publish_ide(self):
        """A disk is there / the cartridge is there (IDE_CFG; kept while the core is held)."""
        cart = self.msx["cart"] if self.machine == 2 else self.coco["cart"]
        self.r.write32(R_IDE_CFG, (1 if self.ide is not None and self.ide.sectors else 0) | (2 if cart is not None else 0) |
                       (4 if self.machine == 2 and self.msx["disk"] is not None else 0) |
                       (8 if self.machine == 1 and any(self.media[COCO_DRIVE0 + i] is not None and self.media[COCO_DRIVE0 + i].ok for i in range(4)) else 0))

    def mount_ide(self, blob, name):
        if len(blob) < 512 or len(blob) % 512:
            raise ValueError("an IDE image is a whole number of 512 byte sectors")
        self.eject_ide(keep_cfg=True)
        open(self._path("ide0.img"), "wb").write(blob)
        self.ide = IdeDisk(self._path("ide0.img"))
        self.ide_name = name
        self._save_meta()
        self.publish_ide()
        return {"sectors": self.ide.sectors}

    def adopt_ide(self, path, name):
        """A finished image file (any size) becomes the IDE disk."""
        size = os.path.getsize(path)
        if size < 512 or size % 512:
            os.remove(path)
            raise ValueError("an IDE image is a whole number of 512 byte sectors")
        self.eject_ide(keep_cfg=True)
        os.replace(path, self._path("ide0.img"))
        self.ide = IdeDisk(self._path("ide0.img"))
        self.ide_name = name
        self._save_meta()
        self.publish_ide()
        return {"sectors": self.ide.sectors}

    def rescan_ide(self):
        """/var/lib/cp300/ide0.img was copied there by hand (a big image): use it."""
        path = self._path("ide0.img")
        if not os.path.exists(path):
            raise ValueError("there is no ide0.img in %s" % self.datadir)
        size = os.path.getsize(path)
        if size < 512 or size % 512:
            raise ValueError("ide0.img is not a whole number of 512 byte sectors")
        self.eject_ide(keep_cfg=True)
        self.ide = IdeDisk(path)
        self.ide_name = self.ide_name or "ide0.img"
        self._save_meta()
        self.publish_ide()
        return {"sectors": self.ide.sectors}

    def eject_ide(self, keep_cfg=False):
        if self.ide is not None:
            self.ide.close()
            self.ide = None
        if not keep_cfg:
            try:
                os.remove(self._path("ide0.img"))
            except OSError:
                pass
            self.ide_name = ""
            self._save_meta()
            self.publish_ide()

    def service_ide(self):
        """Answer the CP-400 hard disk's pending request (bvf_ide.v): read, write or identify one sector. For a read the
        window is filled before the ack; for a write it is read first."""
        req = self.r.read32(R_IDE_REQ)
        lba = self.r.read32(R_IDE_LBA) & 0x0FFFFFFF
        err = 0
        d = self.ide
        if d is None:
            err = IDE_ERR_IDNF
        elif (req & 7) in (0, 4, 3):
            # IDENTIFY. Gateware 4308 and 4310 never show bit 2 of the request kind on the bus (a pending request with kind 0 is
            # the identify; cause not found, the simulation shows 4): so kind 0 counts as identify, and the next gateware encodes
            # identify as 3 (read + write, which no command is)
            self.r.write_block(W_IDE, d.identify())
        elif req & 1:
            data = d.read(lba)
            if data is None:
                err = IDE_ERR_IDNF
            else:
                self.r.write_block(W_IDE, sector_words(data))
        elif req & 2:
            # the write side of the data port is not understood yet (the last byte pair cannot be recovered from the lagging low
            # bytes): refuse, rather than damage the disk
            err = IDE_ERR_ABRT
        self.r.write32(R_IDE_ACK, 1 | (err << 8))
        self.stats["requests"] += 1
        self.last_disk = time.monotonic()
        self.stats["errors"] += 1 if err else 0

    COLD = 0x80

    def ctrl_word(self, reset=False, hold=False, cold=False):
        return ((self.COLD if cold else 0) | (1 if self.ctrl["run"] else 0) | (2 if reset else 0) | (4 if self.ctrl["turbo"] else 0)
                | (8 if self.ctrl["wp"] else 0) | ((self.machine & 3) << CTRL_MACH_SHIFT) | ((self.machine >> 2) << CTRL_MACH_HI) | (CTRL_HOLD if hold else 0))

    # -- the Alice's emulator process
    @staticmethod
    def _emu_binary():
        """alice_emu: next to this file (the package), in the repository's build folder, or compiled here from the sources."""
        import subprocess
        import tempfile
        for p in (os.path.join(HERE, "alice_emu"), os.path.join(HERE, "..", "alice", "emu", "build", "alice_emu")):
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
        src = os.path.join(HERE, "..", "alice", "emu")
        if not os.path.exists(os.path.join(src, "alice_emu.c")):
            src = os.path.join(HERE, "alice_emu_src")
        out = os.path.join(tempfile.gettempdir(), "cp300_alice_emu")
        subprocess.check_call(["gcc", "-O2", "-std=gnu99", "-o", out, os.path.join(src, "alice_emu.c"), os.path.join(src, "mc6803.c")])
        return out

    def _start_emu(self):
        """Run the 6803 emulator for the Alice (after the gateware runs: its first writes are the video RAM)."""
        self._stop_emu()
        emu_args = getattr(self.r, "emu_args", None)
        if emu_args is None:                          # simulated registers: no emulator
            return
        import subprocess
        rom = self._path("alice.rom")
        self.emu = subprocess.Popen([self._emu_binary(), rom] + emu_args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        fd = self.emu.stdout.fileno()
        if fcntl is not None:
            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        self.tape.emu_free, self.tape.emu_active, self.tape.emu_buf = 0, False, b""
        self.tape.play = self.tape.rec = False

    def _stop_emu(self):
        if self.emu is not None:
            self.emu.terminate()
            try:
                self.emu.wait(2)
            except Exception:
                self.emu.kill()
            self.emu = None

    def set_machine(self, m):
        """Switch machine: hold the core, load that machine's ROMs, release it (only if its ROMs are here)."""
        self._stop_emu()
        if getattr(self, "tape", None) is not None:
            self.tape.play = False
            self.tape.rec = False
        self.machine = m
        open(self._path("machine"), "w").write(str(self.machine))
        self.last_frame = -1
        self.ctrl["run"] = 0
        self.r.write32(R_CTRL, self.ctrl_word())        # run = 0: the machine select takes effect
        if self.roms_ready():
            self.start()

    def apply_ctrl(self, reset=False):
        v = self.ctrl_word(reset)
        self.publish_drives()                         # "write protect all" is the daemon's job now
        self.r.write32(R_CTRL, v)
        if reset and self.machine == 5 and self.emu is not None:
            self.emu.send_signal(signal.SIGUSR1)      # the emulated 6803 resets, its RAM stays

    def start(self):
        """POWER ON: hold the core, load the ROMs and the drive flags, then release it with the RAM cleared (the machine starts
        from nothing; RESET, by contrast, keeps the RAM as on the real machines)."""
        self._stop_emu()
        self.ctrl["run"] = 0
        self.r.write32(R_CTRL, self.ctrl_word())
        if not self.roms_ready():
            return False
        self.load_roms()
        self.publish_ide()
        self.ctrl["run"] = 1
        self.publish_drives()
        self.r.write32(R_CTRL, self.ctrl_word(cold=True))
        if self.machine == 5:
            self._start_emu()
        return True

    def power_off(self):
        """POWER OFF: the machine is held in reset (the RAM is not touched: the next power on clears it)."""
        self._stop_emu()
        self.ctrl["run"] = 0
        self.r.write32(R_CTRL, self.ctrl_word())

    # -- disks
    def mount(self, n, blob, name):
        if dsk2dmk is None:
            raise ValueError("dsk2dmk.py not found next to the daemon: only DMK images can be mounted")
        dmk, info = dsk2dmk.convert(bytes(blob))
        self.disks[n] = bytearray(dmk)
        self.names[n] = name
        self.dirty[n] = True
        self.save_dirty()
        self._save_meta()
        self._attach(n)
        self.publish_drives()
        return info

    def mount_msx(self, n, blob, name):
        """MSX disk n (0 or 1): a raw .DSK image of 512 byte sectors (720 KB, 360 KB, 640 KB, 320 KB)."""
        if len(blob) < 512 or len(blob) % 512 or len(blob) > 2 * 1024 * 1024:
            raise ValueError("an MSX disk image is a whole number of 512 byte sectors (720 KB for a 3.5 inch double sided disk)")
        slot = MSX_DRIVE0 + n
        img = bytearray(blob)
        if not RawDsk(img).ok:
            raise ValueError("this size is not an MSX disk (use 360 KB, 720 KB, 320 KB or 640 KB images)")
        self.disks[slot] = img
        self.names[slot] = name
        self.dirty[slot] = True
        self.save_dirty()
        self._save_meta()
        self._attach(slot)
        self.publish_drives()
        d = self.media[slot]
        return {"tracks": d.tracks, "sides": d.heads, "sectors": d.spt}

    def mount_coco(self, n, blob, name):
        """CP-400 floppy drive n (0-3): a CoCo .DSK or .JVC image (256 byte sectors, 18 per track, 35 or 40 tracks)."""
        slot = COCO_DRIVE0 + n
        img = bytearray(blob)
        d = RawDsk(img, 256)
        if not d.ok:
            raise ValueError("not a CoCo disk image (a .DSK of 35 or 40 tracks x 18 sectors x 256 bytes, one or two sides, or a .JVC)")
        self.disks[slot] = img
        self.names[slot] = name
        self.dirty[slot] = True
        self.save_dirty()
        self._save_meta()
        self._attach(slot)
        self.publish_drives()
        return {"tracks": d.tracks, "sides": d.heads, "sectors": d.spt}

    def mount_hd(self, h, blob, name):
        """Hard disk h (0 or 1): an HDV image, used as it is. Reed's header: 56 CB 10, cylinders at 28,
        sectors per cylinder at 29 (a multiple of 32), then 256-byte sectors."""
        blob = bytes(blob)
        if len(blob) < 512 or blob[0:3] != b"\x56\xcb\x10" or blob[29] % 32:
            raise ValueError("not an HDV hard disk image (header 56 CB 10, sectors per cylinder a multiple of 32)")
        n = HD_SLOT + h
        # the FreHD's boot ROM and menu find their images on the "SD card": an image loaded here is put there too (unless it is
        # that very file, which the menu's own mount passes in)
        base = os.path.basename(name) or "hd%d.hdv" % h
        if not base.startswith("."):
            dst = os.path.join(self.sd.folder, base)
            try:
                if not (os.path.isfile(dst) and os.path.getsize(dst) == len(blob) and open(dst, "rb").read() == blob):
                    open(dst, "wb").write(blob)
            except OSError:
                pass
        self.disks[n] = bytearray(blob)
        self.names[n] = name
        self.dirty[n] = True
        self.save_dirty()
        self._save_meta()
        self._attach(n)
        self.publish_drives()
        return {"cylinders": blob[28] or 256, "sectors_per_cylinder": blob[29] or 256}

    def eject(self, n):
        self.disks[n] = None
        self.names[n] = ""
        p = self._disk_path(n)
        if os.path.exists(p):
            os.remove(p)
        self._save_meta()
        self._attach(n)
        self.publish_drives()

    def _hd_info(self):
        """What the FreHD's INFO_DRIVE and READ_HEADER tell about the two mounted images: [(name, header, protected)]."""
        out = []
        for h in range(2):
            n = HD_SLOT + h
            d = self.disks[n]
            m = self.media[n]
            out.append((self.names[n], bytes(d[:256]) if d is not None and m is not None and m.ok else None,
                        n < len(self.media) and m is not None and self._protected(n)))
        return out

    def service_frehd(self):
        """One command of the FreHD interface (bvf_frehd.v): REQ has the command, the step, the size and the drive; the
        data of the Z80's data phase is in the window. The answer (status, error, size) goes into FRH_ACK after the data."""
        req = self.r.read32(R_FRH_REQ)
        if not req & 0x200:
            return
        cmd, step, size = req & 0xFF, (req >> 8) & 1, (req >> 16) & 0x1FF
        drive = ((req >> 10) & 1) | (((req >> 26) & 1) << 1)
        buf = b""
        if step and size:
            buf = self.r.read_block(W_FRH, ((size + 3) // 4) * 4 * 4)[0::4][:size]
        try:
            status, err, rsize, data = self.sd.command(cmd, step, size, buf, drive)
        except Exception as e:                      # a broken file must not stop the daemon
            print("cp300d: FreHD command %02X failed: %r" % (cmd, e), flush=True)
            status, err, rsize, data = 0x51, 3, 0, None
        if data:
            self.r.write_block(W_FRH, b"".join(struct.pack("<I", b) for b in data))
        self.r.write32(R_FRH_ACK, status | err << 8 | rsize << 16)
        self.stats["requests"] += 1

    def service(self):
        """Answer one sector request of the floppy or hard disk controller (bvf_fdc.v). The order matters: REQ is read
        before ACK rises (the request drops then), and the data moves only while ACK is up."""
        st = self.r.read32(R_STATUS)
        if st & ST_IDE:
            self.service_ide()
            return True
        if st & ST_FRH:
            self.service_frehd()
            return True
        if not st & ST_PENDING:
            return False
        req = self.r.read32(R_REQ)
        track, trkreg, sec = (req >> 8) & 0xFF, (req >> 16) & 0xFF, (req >> 24) & 0xFF
        if req & RQ_HD:
            n = HD_SLOT + ((req >> 4) & 1)
        elif self.machine == 1:
            n = COCO_DRIVE0 + ((req >> 4) & 3)                                      # the CP-400's four drives (256 byte sectors)
        elif self.machine == 2:
            n = MSX_DRIVE0 + ((req >> 4) & 3) if ((req >> 4) & 3) < 2 else None     # the MSX1's two drives (512 byte sectors)
        else:
            n = (req >> 4) & 3
        side = 1 if req & RQ_SIDE else 0
        m = self.media[n] if n is not None else None
        usable = m is not None and m.ok
        secsize = getattr(m, "secsize", 256)
        if req & RQ_RD:
            if not usable:
                res, data = 0, None
            elif req & RQ_HD:
                res, data = m.read_sector(track, trkreg, sec)
            else:
                res, data = m.read_sector(track, side, trkreg, sec)
            self.r.write32(R_ACK, 1)
            if res & DMK_FOUND:
                self.r.write_block(W_SEC, data)
            self.r.write32(R_ACK, res << 8)
        elif req & RQ_WR:
            self.r.write32(R_ACK, 1)                  # the gateware copies the controller's buffer for us
            for _ in range(1000):
                if not self.r.read32(R_STATUS) & ST_COPY:
                    break
            data = self.r.read_block(W_SEC, secsize)
            ok = usable and not self._protected(n)
            if ok:
                if req & RQ_HD:
                    ok = m.write_sector(track, trkreg, sec, data)
                else:
                    ok = m.write_sector(track, side, trkreg, sec, data, bool(req & RQ_DAM))
            if ok:
                self.dirty[n] = True
            res = DMK_FOUND if ok else 0
            self.r.write32(R_ACK, res << 8)
        else:                                         # read address
            res, data = m.read_address(track, side) if usable and not req & RQ_HD else (0, None)
            self.r.write32(R_ACK, 1)
            if res & DMK_FOUND:
                self.r.write_block(W_SEC, data + b"\0\0")
            self.r.write32(R_ACK, res << 8)
        self.stats["requests"] += 1
        self.stats["errors"] += 0 if res & DMK_FOUND else 1
        return True

    # -- picture, keys, audio
    def new_frame4(self):
        """CP-400: the picture as 24576 bytes (4 bits per pixel, pixel x = nibble x%8 of word x/8), or None if unchanged.
        There is one buffer: hold it (the writer starts no new frame), wait for the frame in progress, read, release."""
        cnt = self.r.read32(R_FRAME) & 0xFFFF
        if cnt == self.last_frame:
            return None
        self.r.write32(R_CTRL, self.ctrl_word(hold=True))
        try:
            t = time.monotonic()
            while not (self.r.read32(R_STATUS) & ST_LATEST):
                if time.monotonic() - t > 0.05:
                    self.stats["dropped"] += 1
                    return None
            cnt = self.r.read32(R_FRAME) & 0xFFFF
            data = self.r.read_block(W_FRAME, COCO_FRAME_BYTES)
        finally:
            self.r.write32(R_CTRL, self.ctrl_word())
        self.last_frame = cnt
        self.frame_seq = (self.frame_seq + 1) & 0xFFFF
        self.stats["frames"] += 1
        return data

    def new_frame(self):
        """The newest complete frame as 12288 bytes (pixel x = bit x%8 of byte x/8), or None if unchanged."""
        if self.machine != 0:                    # the CP-400, the MSX1, the Spectrum: 256 x 192 colour indexes
            return self.new_frame4()
        for _ in range(3):
            f0 = self.r.read32(R_FRAME)
            cnt, buf = f0 & 0xFFFF, (f0 >> 16) & 1
            if cnt == self.last_frame:
                return None
            data = self.r.read_block(W_FRAME + buf * 0x4000, FRAME_BYTES)
            f1 = self.r.read32(R_FRAME)
            if ((f1 & 0xFFFF) - cnt) & 0xFFFF < 2:           # the writer did not reach this buffer meanwhile
                self.last_frame = cnt
                self.frame_seq = (self.frame_seq + 1) & 0xFFFF
                self.stats["frames"] += 1
                return data
            self.stats["dropped"] += 1
        return None

    def set_keys(self, keys):
        self.keys = keys
        self.r.write32(R_KEYS_LO, keys & 0xFFFFFFFF)
        self.r.write32(R_KEYS_HI, (keys >> 32) & 0xFFFFFFFF)
        if self.machine == 2:
            self.r.write32(R_KEYS2, (keys >> 64) & 0xFFFFFF)

    def audio_events(self):
        n = self.r.read32(R_AUDIO)
        out = []
        for _ in range(min(n, 128)):
            w = self.r.read32(R_AUDIO_HEAD)
            out.append((w & 0x7FFFFF, w >> 23))
            self.r.write32(R_AUDIO_HEAD, 0)
        return out

    def debug(self):
        """Registers and bus timing, for bring-up: GET /api/debug (all accesses are 32 bit). It does not change the machine's
        state: only the keys registers are written, and they are put back."""
        r = self.r
        out = {"ctrl": hex(r.read32(R_CTRL)), "status": hex(r.read32(R_STATUS)), "frame": hex(r.read32(R_FRAME)),
               "req": hex(r.read32(R_REQ)), "drives": hex(r.read32(R_DRIVES)), "audio_count": r.read32(R_AUDIO),
               "irqs": self.stats["irqs"]}
        # the CP-400's CPU: two samples a little apart (an address that changes = running; the same address with halt = waiting for the disk)
        dbg = []
        for _ in range(4):
            w = r.read32(R_DEBUG)
            dbg.append({"cpu_a": "%04X" % (w & 0xFFFF), "halt": (w >> 16) & 1, "drq": (w >> 17) & 1, "intrq": (w >> 18) & 1,
                        "fdc_present": (w >> 19) & 1, "nmi": (w >> 20) & 1, "fdc_ctl": "%02X" % (w >> 24)})
            time.sleep(0.003)
        out["cp400_cpu"] = dbg
        if self.machine != 1:                                # the shared Z80's bus, sampled 32 times: the address that repeats is where it is
            z, ws = [], []
            for _ in range(32):
                w = r.read32(R_DEBUG)
                ws.append(w)
                z.append("%04X%s" % (w & 0xFFFF, "".join(n for n, b in (("m", 16), ("i", 17), ("r", 18), ("w", 19), ("1", 20)) if (w >> b) & 1)))
                time.sleep(0.001)
            out["z80_bus"] = z
            if self.machine == 3:                            # last attribute write (data/count), the ULA's last attribute and bitmap
                out["zx_ula"] = ["w%02X*%d at%02X bm%02X" % (w >> 24, (w >> 16) & 255, (w >> 8) & 255, w & 255) for w in ws[:8]]
        t = time.perf_counter()
        for _ in range(1000):
            r.read32(R_ID)
        out["read32_us"] = round((time.perf_counter() - t) * 1000, 2)
        t = time.perf_counter()
        r.read_block(W_FRAME, FRAME_BYTES)
        out["read_block_ms"] = round((time.perf_counter() - t) * 1000, 2)
        # do writes stick? (all zero reads would mean the register block is held in reset)
        r.write32(R_KEYS_LO, 0xA5A55A5A)
        out["keys_lo_readback"] = hex(r.read32(R_KEYS_LO))
        r.write_block(R_KEYS_LO, bytes([0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55]))
        out["block_write_readback"] = [hex(r.read32(R_KEYS_LO)), hex(r.read32(R_KEYS_HI))]
        self.set_keys(self.keys)
        return out

    def state(self):
        return {"run": self.ctrl["run"], "turbo": self.ctrl["turbo"], "wp": self.ctrl["wp"],
                "machine": MACH_NAMES[self.machine],
                "roms": {"system": self.sysrom is not None, "chargen": self.chargen is not None,
                         "cp400bas": self.coco["bas"] is not None, "cp400ext": self.coco["ext"] is not None,
                         "cp400cart": self.coco["cart"] is not None,
                         "msx1bios": self.msx["bios"] is not None, "msx1p2": self.msx["p2"] is not None,
                         "msx1cart": self.msx["cart"] is not None, "msx1disk": self.msx["disk"] is not None, "zx48": self.zxrom is not None,
                         "mc1000": self.mcrom is not None, "alice": self.alicerom is not None},
                "ide": {"name": self.ide_name, "size": self.ide.sectors * 512 if self.ide is not None else 0},
                "drives": [{"name": self.names[n], "size": len(self.disks[n]) if self.disks[n] is not None else 0}
                           for n in range(4)],
                "hd": [{"name": self.names[n], "size": len(self.disks[n]) if self.disks[n] is not None else 0}
                       for n in (HD_SLOT, HD_SLOT + 1)],
                "cocodisks": [{"name": self.names[n], "size": len(self.disks[n]) if self.disks[n] is not None else 0}
                              for n in range(COCO_DRIVE0, COCO_DRIVE0 + 4)],
                "msxdisks": [{"name": self.names[n], "size": len(self.disks[n]) if self.disks[n] is not None else 0}
                             for n in (MSX_DRIVE0, MSX_DRIVE0 + 1)],
                "sd": self.sd.listing(),
                "sdfiles": [{"name": f, "size": os.path.getsize(os.path.join(self.sd.folder, f))} for f in self.sd.listing()],
                "tape": self.tape.state(),
                "stats": self.stats}


# ---------------------------------------------------------------- HTTP + WebSocket (RFC 6455, enough for one page)
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml"}


def ws_frame(opcode, payload):
    n = len(payload)
    if n < 126: head = struct.pack("!BB", 0x80 | opcode, n)
    elif n < 65536: head = struct.pack("!BBH", 0x80 | opcode, 126, n)
    else: head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
    return head + payload


async def ws_read(reader):
    h = await reader.readexactly(2)
    op, n = h[0] & 0x0F, h[1] & 0x7F
    if n == 126: n = struct.unpack("!H", await reader.readexactly(2))[0]
    elif n == 127: n = struct.unpack("!Q", await reader.readexactly(8))[0]
    mask = await reader.readexactly(4) if h[1] & 0x80 else None
    data = await reader.readexactly(n)
    if mask:
        data = bytes(b ^ mask[i & 3] for i, b in enumerate(data))
    return op, data


class Server:
    def __init__(self, dev, webdir):
        self.dev = dev
        self.webdir = webdir
        self.clients = set()
        self.keys = 0
        self.irq_fd = None                  # set by pump() when the device has the disk request interrupt
        self.irq_seen = False
        self.wake = None

    async def handle(self, reader, writer):
        try:
            line = await reader.readline()
            if not line:
                return
            method, target, _ = line.decode("latin1").split(" ", 2)
            headers = {}
            while True:
                h = (await reader.readline()).decode("latin1").strip()
                if not h:
                    break
                k, v = h.split(":", 1)
                headers[k.strip().lower()] = v.strip()
            body = b""
            url = urlparse(target)
            if method == "PUT" and url.path == "/api/ide" and "content-length" in headers:
                return await self.put_ide_stream(reader, writer, url, int(headers["content-length"]))
            if "content-length" in headers:
                n = int(headers["content-length"])
                if n > 20 * 1024 * 1024:                   # an HDV can be 16 MB (nginx: client_max_body_size)
                    return await self.reply(writer, 413, b"too big")
                body = await reader.readexactly(n)
            if url.path == "/ws" and headers.get("upgrade", "").lower() == "websocket":
                return await self.websocket(reader, writer, headers)
            if url.path.startswith("/api/"):
                return await self.api(writer, method, url, body)
            if method != "GET":
                return await self.reply(writer, 405, b"method not allowed")
            return await self.static(writer, url.path)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def put_ide_stream(self, reader, writer, url, n):
        """PUT /api/ide: an IDE disk image of any size goes straight to a file (no copy in memory), then it is the disk."""
        dev = self.dev
        part = dev._path("ide0.img.part")
        try:
            left = n
            with open(part, "wb") as f:
                while left:
                    chunk = await reader.read(min(left, 1 << 20))
                    if not chunk:
                        raise ConnectionError("upload cut short")
                    f.write(chunk)
                    left -= len(chunk)
            info = dev.adopt_ide(part, parse_qs(url.query).get("name", ["ide0.img"])[0])
        except ValueError as e:
            os.path.exists(part) and os.remove(part)
            return await self.json(writer, {"ok": False, "error": str(e)}, 400)
        except (ConnectionError, OSError):
            os.path.exists(part) and os.remove(part)
            raise
        await self.push_state()
        return await self.json(writer, {"ok": True, "info": info})

    async def reply(self, writer, code, body, ctype="text/plain", extra=""):
        reason = {200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Too Large", 500: "Error"}.get(code, "OK")
        writer.write(("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\n%sConnection: close\r\n\r\n"
                      % (code, reason, ctype, len(body), extra)).encode() + body)
        await writer.drain()

    async def static(self, writer, path):
        if path == "/":
            path = "/index.html"
        full = os.path.normpath(os.path.join(self.webdir, path.lstrip("/")))
        if not full.startswith(os.path.normpath(self.webdir)) or not os.path.isfile(full):
            return await self.reply(writer, 404, b"not found")
        await self.reply(writer, 200, open(full, "rb").read(), TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))

    async def api(self, writer, method, url, body):
        parts = url.path.strip("/").split("/")[1:]
        q = parse_qs(url.query)
        dev = self.dev
        try:
            if parts == ["state"]:
                return await self.json(writer, dev.state())
            if parts == ["debug"]:
                out = dev.debug()
                # the hardware frame rate over one second; the pump keeps serving the disk meanwhile
                f0 = dev.r.read32(R_FRAME) & 0xFFFF
                await asyncio.sleep(1.0)
                out["frames_per_second"] = ((dev.r.read32(R_FRAME) & 0xFFFF) - f0) & 0xFFFF
                out["irq"] = self.irq_fd is not None
                return await self.json(writer, out)
            if parts[0] == "disk" and len(parts) == 2 and parts[1] in "0123":
                n = int(parts[1])
                if method == "PUT":
                    info = dev.mount(n, body, q.get("name", ["disk%d.dsk" % n])[0])
                    await self.push_state()
                    return await self.json(writer, {"ok": True, "info": info})
                if method == "DELETE":
                    dev.eject(n)
                    await self.push_state()
                    return await self.json(writer, {"ok": True})
                if method == "GET" and dev.disks[n] is not None:
                    dev.save_dirty()
                    return await self.reply(writer, 200, bytes(dev.disks[n]), "application/octet-stream",
                                            'Content-Disposition: attachment; filename="%s"\r\n' % (os.path.splitext(dev.names[n])[0] or "disk") + ".dmk")
            if parts[0] == "tape":
                if len(parts) == 1 and method == "PUT":
                    words = tapefmt.load(q.get("name", ["tape.wav"])[0], body, MACH_NAMES[dev.machine])
                    dev.tape.load(q.get("name", ["tape"])[0], words)
                    await self.push_state()
                    return await self.json(writer, {"ok": True, "entries": len(words), "seconds": round(tapefmt.duration_us(words) / 1e6, 1)})
                if len(parts) == 1 and method == "DELETE":
                    dev.tape.eject()
                    await self.push_state()
                    return await self.json(writer, {"ok": True})
                if len(parts) == 1 and method == "POST":
                    c = json.loads(body or b"{}")
                    dev.tape.command(c.get("cmd", ""), c.get("value"))
                    await self.push_state()
                    return await self.json(writer, dev.tape.state())
                if parts[1:] == ["rec.wav"] and method == "GET":
                    wav = tapefmt.to_wav(dev.tape.records, three_level=(dev.machine == 0))
                    return await self.reply(writer, 200, wav, "audio/wav", 'Content-Disposition: attachment; filename="recording.wav"\r\n')
            if parts[0] == "cocodisk" and len(parts) == 2 and parts[1] in ("0", "1", "2", "3"):
                n = int(parts[1])
                slot = COCO_DRIVE0 + n
                if method == "PUT":
                    info = dev.mount_coco(n, body, q.get("name", ["cocodisk%d.dsk" % n])[0])
                    await self.push_state()
                    return await self.json(writer, {"ok": True, "info": info})
                if method == "DELETE":
                    dev.eject(slot)
                    await self.push_state()
                    return await self.json(writer, {"ok": True})
                if method == "GET" and dev.disks[slot] is not None:
                    dev.save_dirty()
                    return await self.reply(writer, 200, bytes(dev.disks[slot]), "application/octet-stream",
                                            'Content-Disposition: attachment; filename="%s"\r\n' % (os.path.splitext(dev.names[slot])[0] or "cocodisk") + ".dsk")
            if parts[0] == "msxdisk" and len(parts) == 2 and parts[1] in ("0", "1"):
                n = int(parts[1])
                slot = MSX_DRIVE0 + n
                if method == "PUT":
                    info = dev.mount_msx(n, body, q.get("name", ["msxdisk%d.dsk" % n])[0])
                    await self.push_state()
                    return await self.json(writer, {"ok": True, "info": info})
                if method == "DELETE":
                    dev.eject(slot)
                    await self.push_state()
                    return await self.json(writer, {"ok": True})
                if method == "GET" and dev.disks[slot] is not None:
                    dev.save_dirty()
                    return await self.reply(writer, 200, bytes(dev.disks[slot]), "application/octet-stream",
                                            'Content-Disposition: attachment; filename="%s"\r\n' % (os.path.splitext(dev.names[slot])[0] or "msxdisk") + ".dsk")
            if parts[0] == "hd" and len(parts) == 2 and parts[1] in "01":
                h = int(parts[1])
                if method == "PUT":
                    info = dev.mount_hd(h, body, q.get("name", ["hd%d.hdv" % h])[0])
                    await self.push_state()
                    return await self.json(writer, {"ok": True, "info": info})
                if method == "DELETE":
                    dev.eject(HD_SLOT + h)
                    await self.push_state()
                    return await self.json(writer, {"ok": True})
                if method == "GET" and dev.disks[HD_SLOT + h] is not None:
                    dev.save_dirty()
                    return await self.reply(writer, 200, bytes(dev.disks[HD_SLOT + h]), "application/octet-stream",
                                            'Content-Disposition: attachment; filename="%s"\r\n' % (os.path.splitext(dev.names[HD_SLOT + h])[0] or "hd") + ".hdv")
            if parts[0] == "sd":
                # the FreHD's SD card: files of the boot disk (FREHD.ROM), hard disk images the menu mounts
                if len(parts) == 1 and method == "GET":
                    return await self.json(writer, {"files": [{"name": f, "size": os.path.getsize(os.path.join(dev.sd.folder, f))}
                                                              for f in dev.sd.listing()]})
                if len(parts) == 2:
                    name = os.path.basename(parts[1])
                    if not name or name.startswith("."):
                        return await self.json(writer, {"ok": False, "error": "bad name"}, 400)
                    path = os.path.join(dev.sd.folder, name)
                    if method == "GET" and os.path.isfile(path):
                        return await self.reply(writer, 200, open(path, "rb").read(), "application/octet-stream",
                                                'Content-Disposition: attachment; filename="%s"\r\n' % name)
                    if method == "PUT":
                        open(path, "wb").write(body)
                        await self.push_state()
                        return await self.json(writer, {"ok": True, "size": len(body)})
                    if method == "DELETE":
                        if os.path.isfile(path):
                            os.remove(path)
                        await self.push_state()
                        return await self.json(writer, {"ok": True})
                    if method == "POST" and os.path.isfile(path):          # POST /api/sd/<file>?hd=0|1: mount an image of the card
                        info = dev.mount_hd(1 if q.get("hd", ["0"])[0] == "1" else 0, open(path, "rb").read(), name)
                        await self.push_state()
                        return await self.json(writer, {"ok": True, "info": info})
            if parts == ["ide", "rescan"] and method == "POST":
                info = dev.rescan_ide()
                await self.push_state()
                return await self.json(writer, {"ok": True, "info": info})
            if parts == ["ide"]:
                if method == "PUT":
                    info = dev.mount_ide(body, q.get("name", ["ide0.img"])[0])
                    await self.push_state()
                    return await self.json(writer, {"ok": True, "info": info})
                if method == "DELETE":
                    dev.eject_ide()
                    await self.push_state()
                    return await self.json(writer, {"ok": True})
                if method == "GET" and dev.ide is not None:
                    return await self.reply(writer, 200, open(dev._path("ide0.img"), "rb").read(), "application/octet-stream",
                                            'Content-Disposition: attachment; filename="%s"\r\n' % (dev.ide_name or "ide0.img"))
            if parts[0] == "rom" and len(parts) == 2 and parts[1] in ("msx1bios", "msx1p2", "msx1cart", "msx1disk") and method in ("PUT", "DELETE"):
                key = parts[1][4:]
                if method == "DELETE":
                    if key == "bios":
                        return await self.json(writer, {"ok": False, "error": "the BIOS cannot be removed"}, 400)
                    dev.msx[key] = None
                    if os.path.exists(dev._path("msx1%s.rom" % key)):
                        os.remove(dev._path("msx1%s.rom" % key))
                else:
                    if (key == "bios" and len(body) != MSX_BIOS_SIZE) or (key == "p2" and len(body) != MSX_P2_SIZE) or \
                            (key == "cart" and not (0 < len(body) <= MSX_CART_MAX)) or (key == "disk" and len(body) != MSX_DISK_SIZE):
                        return await self.json(writer, {"ok": False, "error": "msx1bios must be 32768 bytes, msx1p2 16384, msx1cart up to 32768, msx1disk 16384"}, 400)
                    dev.msx[key] = body
                    open(dev._path("msx1%s.rom" % key), "wb").write(body)
                if dev.machine == 2 and dev.roms_ready():
                    dev.start()
                await self.push_state()
                return await self.json(writer, {"ok": True})
            if parts[0] == "rom" and len(parts) == 2 and parts[1] == "alice" and method == "PUT":
                if len(body) != ALICE_ROM:
                    return await self.json(writer, {"ok": False, "error": "the Alice ROM must be %d bytes" % ALICE_ROM}, 400)
                dev.alicerom = body
                open(dev._path("alice.rom"), "wb").write(body)
                if dev.machine == 5:
                    dev.start()
                await self.push_state()
                return await self.json(writer, {"ok": True})
            if parts[0] == "rom" and len(parts) == 2 and parts[1] in ("zx48", "mc1000") and method == "PUT":
                zx = parts[1] == "zx48"
                if len(body) != (ZX_ROM if zx else MC_ROM):
                    return await self.json(writer, {"ok": False, "error": "the %s ROM must be %d bytes" % ("Spectrum" if zx else "MC-1000", ZX_ROM)}, 400)
                setattr(dev, "zxrom" if zx else "mcrom", body)
                open(dev._path(parts[1] + ".rom"), "wb").write(body)
                if dev.machine == (3 if zx else 4):
                    dev.start()
                await self.push_state()
                return await self.json(writer, {"ok": True})
            if parts[0] == "rom" and parts[1:] == ["cp400"] and method == "PUT":
                # a complete CP-400 ROM image: [2 byte load address] + Extended BASIC ($8000) + Color BASIC ($A000) [+ a cartridge ($C000):
                # the Disk BASIC] as the files cp400.rom / cp400disk.rom are
                b = bytes(body)
                if len(b) % 8192 == 2:
                    b = b[2:]
                if len(b) not in (16384, 24576):
                    return await self.json(writer, {"ok": False, "error": "a complete CP-400 ROM is 16384 bytes (Extended + Color BASIC) or 24576 (+ the Disk BASIC cartridge), with or without a 2 byte header"}, 400)
                parts_ = {"ext": b[:8192], "bas": b[8192:16384]}
                if len(b) == 24576:
                    parts_["cart"] = b[16384:]
                for key, data in parts_.items():
                    dev.coco[key] = data
                    open(dev._path("cp400%s.rom" % key), "wb").write(data)
                dev.publish_ide()
                if dev.machine == 1 and dev.roms_ready():
                    dev.start()
                await self.push_state()
                return await self.json(writer, {"ok": True, "cartridge": len(b) == 24576})
            if parts[0] == "rom" and parts[1:] == ["cp400cart"] and method == "DELETE":
                dev.coco["cart"] = None
                if os.path.exists(dev._path("cp400cart.rom")):
                    os.remove(dev._path("cp400cart.rom"))
                dev.publish_ide()
                if dev.machine == 1 and dev.roms_ready():
                    dev.start()                                    # restart without the cartridge
                await self.push_state()
                return await self.json(writer, {"ok": True})
            if parts[0] == "rom" and len(parts) == 2 and method == "PUT" and parts[1] in ("cp400bas", "cp400ext", "cp400cart"):
                if len(body) != COCO_ROM:
                    return await self.json(writer, {"ok": False, "error": "%s ROM must be %d bytes" % (parts[1], COCO_ROM)}, 400)
                key = parts[1][5:]
                dev.coco[key] = body
                open(dev._path("cp400%s.rom" % key), "wb").write(body)
                dev.publish_ide()
                if dev.machine == 1 and dev.roms_ready():
                    dev.start()
                await self.push_state()
                return await self.json(writer, {"ok": True})
            if parts[0] == "rom" and len(parts) == 2 and method == "PUT":
                want = {"system": SYS_ROM, "chargen": CHARGEN}.get(parts[1])
                if want is None or len(body) != want:
                    return await self.json(writer, {"ok": False, "error": "%s ROM must be %s bytes" % (parts[1], want)}, 400)
                setattr(dev, "sysrom" if parts[1] == "system" else "chargen", body)
                open(dev._path("system.rom" if parts[1] == "system" else "chargen.rom"), "wb").write(body)
                if dev.roms_ready():
                    dev.start()
                await self.push_state()
                return await self.json(writer, {"ok": True})
            if parts == ["ctrl"] and method == "POST":
                self.ctrl(json.loads(body or b"{}"))
                await self.push_state()
                return await self.json(writer, dev.state())
        except (ValueError, SystemExit) as e:
            return await self.json(writer, {"ok": False, "error": str(e)}, 400)
        return await self.reply(writer, 404, b"no such call")

    async def json(self, writer, obj, code=200):
        await self.reply(writer, code, json.dumps(obj).encode(), "application/json")

    def ctrl(self, c):
        d = self.dev
        if "machine" in c:
            m = MACHINES.get(c["machine"], c["machine"] if c["machine"] in range(len(MACH_NAMES)) else None)
            if m is None:
                raise ValueError("unknown machine %r" % (c["machine"],))
            if m != d.machine:
                d.set_machine(m)
        # the power switch: {"power": 1} switches on (the RAM is cleared), {"power": 0} off; "run" is the old name, "cold" switches on
        power = c["power"] if "power" in c else c["run"] if "run" in c else 1 if c.get("cold") else None
        if power is not None:
            if power:
                if not d.start():
                    d.ctrl["run"] = 0
            else:
                d.power_off()
            return
        for k in ("turbo", "wp"):
            if k in c:
                d.ctrl[k] = 1 if c[k] else 0
        if d.ctrl["run"]:
            d.apply_ctrl(reset=bool(c.get("reset")))
        else:
            d.r.write32(R_CTRL, d.ctrl_word())

    async def push_state(self):
        msg = ws_frame(1, json.dumps(self.dev.state()).encode())
        for c in list(self.clients):
            c.w.write(msg)

    async def websocket(self, reader, writer, headers):
        acc = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + WS_GUID).encode()).digest()).decode()
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        me = _Client(writer)
        self.clients.add(me)
        writer.write(ws_frame(1, json.dumps(self.dev.state()).encode()))
        await writer.drain()
        try:
            while True:
                op, data = await ws_read(reader)
                if op == 8:
                    break
                if op == 9:
                    writer.write(ws_frame(10, data))
                elif op == 1:
                    msg = json.loads(data)
                    if "keys" in msg:
                        self.keys = int(msg["keys"], 16) & ((1 << 88) - 1)
                        self.dev.set_keys(self.keys)
                    if msg.get("keyframe"):
                        me.prev = None                     # the page lost its picture: the next frame is a whole one
                    if "ctrl" in msg:
                        self.ctrl(msg["ctrl"])
                        await self.push_state()
        except (asyncio.IncompleteReadError, ConnectionError, ValueError):
            pass
        finally:
            self.clients.discard(me)
            if not self.clients:
                self.dev.set_keys(0)

    def _on_irq(self):
        try:
            self.dev.stats["irqs"] = self.dev.r.irq_read()
        except OSError:
            pass
        if not self.irq_t:
            self.irq_t = time.monotonic()
        self.irq_seen = True
        self.wake.set()

    async def pump(self):
        """The disk loop: the sector requests of the controllers (floppy, hard disk, IDE) are time critical, the CP-400's
        DOS gives up on a drive that takes more than some tens of ms to answer. So this loop does nothing else: with the
        interrupt a request wakes it at once; the timed wake-up stays as the fallback. The picture, the audio and the saving
        run in `media()`, with the slow parts in threads, so that they never hold a disk request up."""
        dev = self.dev
        self.wake = asyncio.Event()
        self.irq_t = 0.0
        self.irq_fd = getattr(dev.r, "irq_fd", lambda: None)()
        if self.irq_fd is not None:
            asyncio.get_running_loop().add_reader(self.irq_fd, self._on_irq)
        print("cp300d: disk requests by %s" % ("interrupt" if self.irq_fd is not None else "polling"), flush=True)
        self.media_task = asyncio.ensure_future(self.media())
        while True:
            busy = False
            while dev.service():
                busy = True
                if self.irq_t:
                    lat = (time.monotonic() - self.irq_t) * 1000.0
                    self.irq_t = 0.0
                    st = dev.stats
                    st["lat_max_ms"] = max(st["lat_max_ms"], round(lat, 1))
                    if lat > 20.0:
                        st["lat_slow"] += 1
                        st["lat_last_slow"] = (st["lat_last_slow"] + [round(lat)])[-8:]
            if self.irq_seen:
                # unmask only now: the level interrupt has dropped with ACK, a new request raises it again
                self.irq_seen = False
                try:
                    dev.r.irq_unmask()
                except OSError:
                    pass
            if not busy:
                self.irq_t = 0.0                                   # an interrupt that found nothing to do must not stamp the next request
            self.wake.clear()
            try:
                await asyncio.wait_for(self.wake.wait(), 0.0005 if busy else 0.002)
            except asyncio.TimeoutError:
                pass

    async def media(self):
        """Picture, audio and saving. The register reads and the compression run in threads (the loop stays free for the disk)."""
        dev = self.dev
        loop = asyncio.get_running_loop()
        last_save = time.monotonic()
        last_tape = 0.0
        last_frame_t = 0.0
        while True:
            if time.monotonic() - dev.last_disk < 0.1 and time.monotonic() - last_frame_t < 0.1:
                frame = None                                   # a disk request was answered just now: at most 10 pictures a second until it is quiet
                await asyncio.sleep(0.02)
            else:
                frame = await loop.run_in_executor(None, dev.new_frame)
                last_frame_t = time.monotonic()
            if frame is not None and self.clients:
                seq, mach = dev.frame_seq, dev.machine
                for c in list(self.clients):
                    prev = c.prev
                    pl, kind = (frame, 0) if prev is None or len(prev) != len(frame) else (await loop.run_in_executor(None, _xor, frame, prev), 1)
                    c.prev = frame
                    z = await loop.run_in_executor(None, zlib.compress, pl, 1)
                    c.w.write(ws_frame(2, (b"\x01" if mach == 0 else b"\x03") + struct.pack("<HB", seq, kind) + z))
            ev = await loop.run_in_executor(None, dev.audio_events)
            if ev and self.clients:
                msg = ws_frame(2, b"\x02" + b"".join(struct.pack("<IH", t, lv) for t, lv in ev))
                for c in list(self.clients):
                    c.w.write(msg)
            if dev.tape.play or dev.tape.rec or dev.emu is not None:      # (the emulator's status lines are read even when idle)
                await loop.run_in_executor(None, dev.tape.service)
                if time.monotonic() - last_tape > 1.0:
                    last_tape = time.monotonic()
                    await self.push_state()
            if time.monotonic() - last_save > 2:
                await loop.run_in_executor(None, dev.save_dirty)
                last_save = time.monotonic()
            await asyncio.sleep(0.004)


def _xor(a, b):
    """The XOR of two equal length byte strings (as big integers: much faster than a Python loop)."""
    return (int.from_bytes(a, "little") ^ int.from_bytes(b, "little")).to_bytes(len(a), "little")


class _Client:
    def __init__(self, w):
        self.w = w
        self.prev = None


async def main_async(args):
    if args.sim:
        regs = SimRegs()
    elif args.uio:
        regs = MemRegs(args.uio)
    else:
        regs = MemRegs("/dev/mem", int(args.mem, 0))
    dev = Cp300(regs, args.data)
    atexit.register(dev._stop_emu)
    if args.sim and not dev.roms_ready():
        dev.sysrom, dev.chargen = bytes(SYS_ROM), bytes(CHARGEN)
    if dev.roms_ready():
        dev.start()
    srv = Server(dev, args.web)
    server = await asyncio.start_server(srv.handle, args.host, args.port)
    print("cp300d: http://%s:%d/  (%s)" % (args.host, args.port, "simulated registers" if args.sim else "hardware"), flush=True)
    asyncio.get_event_loop().create_task(srv.pump())
    async with server:
        await server.serve_forever()


def main():
    sys.setswitchinterval(0.0005)               # threads give the GIL back after 0.5 ms (the default 5 ms made a disk request wait behind the picture's threads)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--uio", help="UIO device of the gateware, e.g. /dev/uio0")
    g.add_argument("--mem", help="physical base address of the FIC window (through /dev/mem)")
    g.add_argument("--sim", action="store_true", help="simulated registers, no hardware")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8300)
    ap.add_argument("--data", default=os.path.join(HERE, "data"), help="where ROMs and disk images are kept")
    ap.add_argument("--web", default=os.path.join(HERE, "web"))
    args = ap.parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
