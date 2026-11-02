"""The FreHD board's command set (the part of the FreHD that is more than a WD1010), answered from a folder.

The gateware (rtl/bvf_frehd.v) takes the Z80's accesses of ports C2-C5 and hands every command to the host: REQ tells
the command, whether it is the step after COMMAND2 (0) or the step after the data phase (1), and the size; the data
phase's bytes are in the buffer window. This module does what the PIC firmware does (veco/FreHDv1, sw/trs_hard/trs_extra.c),
with a folder as the "SD card": FREHD.ROM and the boot disk's other files, and the hard disk images the menu mounts.

    sd = Frehd(folder, mounter)
    status, error, size, data = sd.command(cmd, step, size, buf, drive)

`buf` holds the bytes the Z80 sent (step 1), `data` the bytes for the Z80 to read (or None). `mounter(drive, blob, name)` mounts
a hard disk image, `drives()` (a callable passed to infodrive) tells what is mounted: [(name, header or None, protected), ...].
"""
import os
import struct
import time

# status for port CF
ST_READY, ST_SEEKDONE, ST_DRQ, ST_ERR = 0x40, 0x10, 0x08, 0x01
DEFAULT = ST_READY | ST_SEEKDONE | ST_DRQ
NODATA = ST_READY | ST_SEEKDONE
FAIL = ST_READY | ST_SEEKDONE | ST_ERR
# FatFS error codes the firmware leaves in ERROR2
FR_OK, FR_DISK_ERR, FR_NOT_READY, FR_NO_FILE, FR_NO_PATH, FR_INVALID_NAME, FR_DENIED, FR_EXIST = 0, 1, 2, 4, 5, 6, 7, 8
FR_INVALID_OBJECT, FR_WRITE_PROTECTED, FR_NOT_ENABLED, FR_INVALID_PARAMETER = 9, 10, 12, 19
# open options (FatFS)
FA_READ, FA_WRITE, FA_CREATE_NEW, FA_CREATE_ALWAYS, FA_OPEN_ALWAYS = 1, 2, 4, 8, 16
VERSION = (2, 17)
MAXDRIVES = 4


class Frehd:
    def __init__(self, folder, mounter=None, drives=None):
        self.folder = folder
        os.makedirs(folder, exist_ok=True)
        self.mounter = mounter
        self.drives = drives or (lambda: [])
        self.file = None
        self.name = ""
        self.dir = None
        self.writable = False

    # -- names: the SD card is a flat folder, names are not case sensitive, "/" and "\" are ignored at the start
    def _find(self, name):
        name = name.replace("\\", "/").strip().lstrip("/")
        if not name or ".." in name.split("/"):
            return None
        d = self.folder
        for part in name.split("/"):
            real = None
            try:
                for f in os.listdir(d):
                    if f.lower() == part.lower():
                        real = f
                        break
            except OSError:
                return None
            if real is None:
                return os.path.join(d, part) if part == name.split("/")[-1] else None
            d = os.path.join(d, real)
        return d

    def listing(self):
        return sorted(f for f in os.listdir(self.folder) if os.path.isfile(os.path.join(self.folder, f)))

    def close(self):
        if self.file is not None:
            self.file.close()
            self.file = None

    @staticmethod
    def _err(code):
        return FAIL, code, 0, None

    def command(self, cmd, step, size, buf, drive=0):
        fn = getattr(self, "_c%x" % cmd, None)
        if fn is None:
            return DEFAULT, 0, size, None
        return fn(step, size, bytes(buf), drive)

    # 0 version
    def _c0(self, step, size, buf, drive):
        return DEFAULT, 0, 6, bytes([VERSION[0], VERSION[1], 0, 0, 0, 0])

    # 1 get time: sec, min, hour, year (since 2000), day, month
    def _c1(self, step, size, buf, drive):
        t = time.localtime()
        return DEFAULT, 0, 6, bytes([t.tm_sec, t.tm_min, t.tm_hour, t.tm_year - 2000, t.tm_mday, t.tm_mon])

    # 2 set time: the host's clock is not touched
    def _c2(self, step, size, buf, drive):
        return DEFAULT, 0, 6 if step == 0 else size, None

    # 3 open file: step 1 gets the options and the name
    def _c3(self, step, size, buf, drive):
        if step == 0:
            return DEFAULT, 0, size, None
        self.close()
        if len(buf) < 2:
            return self._err(FR_INVALID_NAME)
        opt = buf[0]
        name = buf[1:].split(b"\0")[0].decode("latin-1")
        path = self._find(name)
        if path is None:
            return self._err(FR_NO_PATH)
        exists = os.path.isfile(path)
        write = bool(opt & (FA_WRITE | FA_CREATE_NEW | FA_CREATE_ALWAYS | FA_OPEN_ALWAYS))
        if opt & FA_CREATE_NEW and exists:
            return self._err(FR_EXIST)
        if not exists and not opt & (FA_CREATE_NEW | FA_CREATE_ALWAYS | FA_OPEN_ALWAYS):
            return self._err(FR_NO_FILE)
        try:
            if opt & FA_CREATE_ALWAYS or not exists:
                self.file = open(path, "w+b")
            else:
                self.file = open(path, "r+b" if write else "rb")
        except OSError:
            return self._err(FR_DENIED)
        self.name = os.path.basename(path)
        self.writable = write
        return DEFAULT, 0, 4, struct.pack("<I", os.path.getsize(path))

    # 4 read file (size bytes)
    def _c4(self, step, size, buf, drive):
        if self.file is None:
            return self._err(FR_NO_FILE)
        data = self.file.read(size)
        if not data:
            return NODATA, 0, 0, None
        return DEFAULT, 0, len(data), data

    # 5 write file: step 0 asks for 256 bytes, step 1 stores them
    def _c5(self, step, size, buf, drive):
        if self.file is None:
            return self._err(FR_NO_FILE)
        if step == 0:
            return DEFAULT, 0, 256, None
        if not self.writable:
            return self._err(FR_DENIED)
        self.file.write(buf[:size])
        self.file.flush()
        return DEFAULT, 0, size, None

    # 6 close
    def _c6(self, step, size, buf, drive):
        self.close()
        return NODATA, 0, 0, None

    # 7 boot loader (firmware update): not here
    def _c7(self, step, size, buf, drive):
        return self._err(FR_NOT_ENABLED)

    # 8 open directory (step 1 has the path)
    def _c8(self, step, size, buf, drive):
        if step == 0:
            return DEFAULT, 0, size, None
        path = buf.split(b"\0")[0].decode("latin-1").replace("\\", "/").strip("/")
        if path not in ("", "."):
            self.dir = None
            return self._err(FR_NO_PATH)
        self.dir = iter(self.listing())
        return DEFAULT, 0, 0, None

    # 9 read directory: FILINFO of FatFS: size (4), date (2), time (2), attribute (1), name (13)
    def _c9(self, step, size, buf, drive):
        if self.dir is None:
            return self._err(FR_NO_PATH)
        name = next(self.dir, None)
        if name is None:
            return NODATA, 0, 0, None
        p = os.path.join(self.folder, name)
        st = os.stat(p)
        t = time.localtime(st.st_mtime)
        fdate = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
        ftime = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
        short = name.upper()[:12].encode("latin-1", "replace")
        info = struct.pack("<IHHB", st.st_size, fdate, ftime, 0x20) + short.ljust(13, b"\0")
        return DEFAULT, 0, len(info), info

    # a mount drive: step 1 has drive, option, file name
    def _ca(self, step, size, buf, drive):
        if step == 0:
            return DEFAULT, 0, size, None
        if len(buf) < 3 or buf[0] >= MAXDRIVES:
            return self._err(FR_INVALID_PARAMETER)
        d = buf[0]
        name = buf[2:].split(b"\0")[0].decode("latin-1")
        if not name:
            return DEFAULT, 0, 0, None                    # the default image: whatever is mounted already
        path = self._find(name)
        if path is None or not os.path.isfile(path):
            return self._err(FR_NO_FILE)
        if self.mounter is None or d > 1:
            return self._err(FR_NOT_ENABLED)
        try:
            self.mounter(d, open(path, "rb").read(), os.path.basename(path))
        except ValueError:
            return self._err(FR_INVALID_OBJECT)
        return DEFAULT, 0, 0, None

    # b seek (step 0: the position, step 1: set it)
    def _cb(self, step, size, buf, drive):
        if self.file is None:
            return self._err(FR_NO_FILE)
        if step == 0:
            return DEFAULT, 0, 4, struct.pack("<I", self.file.tell())
        self.file.seek(struct.unpack("<I", buf[:4].ljust(4, b"\0"))[0])
        return DEFAULT, 0, 0, None

    # c info about the drives: 19 bytes each
    def _cc(self, step, size, buf, drive):
        out = b""
        mounted = self.drives()
        for n in range(MAXDRIVES):
            if n < len(mounted) and mounted[n][1] is not None:
                name, head, wp = mounted[n]
                cyl = head[28] or 256
                spc = head[29] or 256
                out += bytes([1, 1 if wp else 0, cyl >> 8, cyl & 255, max(1, spc // 32), 32])
                out += os.path.basename(name).upper()[:12].encode("latin-1", "replace").ljust(13, b"\0")
            else:
                out += bytes(19)
        return DEFAULT, 0, len(out), out

    # d disk image (JV1/JV3/DMK from the SD card): not in this firmware build either
    def _cd(self, step, size, buf, drive):
        return self._err(FR_NOT_ENABLED)

    # e the header of the selected hard disk image
    def _ce(self, step, size, buf, drive):
        mounted = self.drives()
        if drive < len(mounted) and mounted[drive][1] is not None:
            return DEFAULT, 0, 256, bytes(mounted[drive][1][:256]).ljust(256, b"\0")
        return FAIL, 0, 0, None
