"""Sector access to the disk images, for the floppy (WD1793) and hard disk (WD1010) controllers of the CP-300.

A Python port of firmware/dmk.c and of the hard disk part of firmware/main.c: on the BeagleV-Fire there is no IO
controller, the daemon answers the controllers' sector requests itself. The images are whole in memory (bytearray),
so there is no block cache.

DMK (David Keil): 16-byte header, then for every track and side a 128-byte table of ID-field pointers followed by
the track bytes as they are on the disk, ID fields, data fields and CRCs included.

HDV (Matthew Reed's FreeHD format): 256-byte header (56 CB 10, write protect in bit 7 of byte 7, cylinders at 28,
sectors per cylinder at 29, 0 = 256), then 256-byte sectors.
"""

DMK_FOUND, DMK_CRCERR, DMK_DELETED = 1, 2, 4      # result bits, the order of the ACK register's b8-b10
ENTRIES = 32                                      # ID-field pointers kept per track (as dmk.c)


def _crc_table():
    tab = []
    for i in range(256):
        c = i << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) if c & 0x8000 else c << 1
        tab.append(c & 0xFFFF)
    return tab


CRC_TAB = _crc_table()


def crc_add(crc, b):
    return ((crc << 8) & 0xFFFF) ^ CRC_TAB[(crc >> 8) ^ b]


def crc_start(dd, mark):
    crc = 0xFFFF
    if dd:
        for _ in range(3):
            crc = crc_add(crc, 0xA1)
    return crc_add(crc, mark)


class Dmk:
    """One mounted DMK image. `ok` is False for an image the controller cannot use (the drive is then not ready)."""

    def __init__(self, img):
        self.img = img                            # bytearray, changed in place by write_sector
        self.ok = False
        self.ctrack = self.cside = None           # the track whose pointer table is in ptrs
        self.ptrs = []
        self.ra_next = 0                          # next ID field for READ ADDRESS
        if len(img) < 16:
            return
        self.readonly = img[0] == 0xFF
        self.ntracks = img[1]
        self.tlen = img[2] | img[3] << 8
        self.nsides = 1 if img[4] & 0x10 else 2
        self.doubled = not (img[4] & 0xC0)        # single density bytes are stored twice
        self.ok = 0 < self.ntracks <= 100 and 0x80 + 16 <= self.tlen <= 0x2940

    def _byte(self, off):
        if off >= len(self.img):
            raise IndexError
        return self.img[off]

    def _load_track(self, track, side):
        """The pointer table of a track; False if the track is not in the image."""
        if track >= self.ntracks or side >= self.nsides:
            return False
        if (track, side) == (self.ctrack, self.cside):
            return True
        base = 16 + (track * self.nsides + side) * self.tlen
        ptrs = []
        for i in range(ENTRIES):
            p = self._byte(base + 2 * i) | self._byte(base + 2 * i + 1) << 8
            if not p:
                break
            ptrs.append(p)
        self.base, self.ptrs = base, ptrs
        self.ctrack, self.cside = track, side
        self.ra_next = 0
        return True

    def _entry(self, i):
        """Where entry i's ID mark is: (file offset, step between bytes, double density)."""
        p = self.ptrs[i]
        dd = bool(p & 0x8000)
        return self.base + (p & 0x3FFF), 2 if self.doubled and not dd else 1, dd

    def _find(self, trkreg, sec):
        """The 256-byte sector with ID (trkreg, sec) on the loaded track: (pos, step, dd, unit of the data mark).

        The ID fields are scanned in table order (dmk.c's DMK_GUESS=0 behaviour; with duplicate IDs on one track, a
        copy protection trick, the first one wins)."""
        end = self.base + self.tlen
        for i in range(len(self.ptrs)):
            pos, st, dd = self._entry(i)
            if self._byte(pos) != 0xFE or self._byte(pos + st) != trkreg or self._byte(pos + 3 * st) != sec:
                continue
            if self._byte(pos + 4 * st) != 1:             # only 256-byte sectors
                continue
            for k in range(7, 90):
                if pos + k * st >= end:
                    break
                if 0xF8 <= self._byte(pos + k * st) <= 0xFB:
                    return pos, st, dd, k
        return None

    def read_sector(self, track, side, trkreg, sec):
        """(DMK_* flags, 256 bytes); flags 0 = not found."""
        try:
            if not self.ok or not self._load_track(track, side):
                return 0, None
            f = self._find(trkreg, sec)
            if f is None:
                return 0, None
            pos, st, dd, k = f
            mark = self._byte(pos + k * st)
            crc = crc_start(dd, mark)
            data = bytearray(256)
            for j in range(256):
                v = self._byte(pos + (k + 1 + j) * st)
                data[j] = v
                crc = crc_add(crc, v)
            p = pos + (k + 257) * st
            stored = self._byte(p) << 8 | self._byte(p + st)
        except IndexError:                                 # a short image
            return 0, None
        res = DMK_FOUND
        if stored != crc:
            res |= DMK_CRCERR
        if mark != 0xFB:
            res |= DMK_DELETED
        return res, bytes(data)

    def write_sector(self, track, side, trkreg, sec, data, deleted=False):
        """True if written (data mark, data and CRC; single density bytes into both copies)."""
        try:
            if not self.ok or self.readonly or not self._load_track(track, side):
                return False
            f = self._find(trkreg, sec)
            if f is None:
                return False
            pos, st, dd, k = f
            last = pos + (k + 258) * st + st - 1           # last byte touched: the second CRC byte's copy
            if last >= len(self.img):
                return False
        except IndexError:
            return False
        mark = 0xF8 if deleted else 0xFB
        crc = crc_start(dd, mark)
        out = [mark]
        for v in data[:256]:
            out.append(v)
            crc = crc_add(crc, v)
        out += [crc >> 8, crc & 0xFF]
        for u, v in enumerate(out):
            p = pos + (k + u) * st
            self.img[p] = v
            if st == 2:
                self.img[p + 1] = v
        return True

    def read_address(self, track, side):
        """(DMK_FOUND or 0, the next ID field of the track: C H R N CRC1 CRC2)."""
        try:
            if not self.ok or not self._load_track(track, side) or not self.ptrs:
                return 0, None
            i = self.ra_next if self.ra_next < len(self.ptrs) else 0
            self.ra_next = i + 1
            pos, st, _ = self._entry(i)
            return DMK_FOUND, bytes(self._byte(pos + (u + 1) * st) for u in range(6))
        except IndexError:
            return 0, None


class Hdv:
    """One mounted FreeHD hard disk image (HDV)."""

    def __init__(self, img):
        self.img = img
        self.ok = len(img) >= 256 and img[0:3] == b"\x56\xcb\x10" and not img[29] % 32
        if self.ok:
            self.readonly = bool(img[7] & 0x80)
            self.cyls = img[28] or 256
            self.spc = img[29] or 256                     # sectors per cylinder

    def _offset(self, cyl, head, sec):
        """File offset of a sector, or None if it is outside the drive (as firmware/main.c hd_service)."""
        if not self.ok or cyl >= self.cyls or head >= self.spc >> 5 or sec > 32:
            return None
        off = 256 * (cyl * self.spc + (head << 5) + (sec & 31) + 1)
        return off if off + 256 <= len(self.img) else None

    @staticmethod
    def chs(track, trkreg, sec):
        """The WD1010's request fields: cylinder low in track, cylinder high in trkreg b1:0, head in trkreg b4:2."""
        return ((trkreg & 3) << 8) | track, (trkreg >> 2) & 7, sec

    def read_sector(self, track, trkreg, sec):
        off = self._offset(*self.chs(track, trkreg, sec))
        if off is None:
            return 0, None
        return DMK_FOUND, bytes(self.img[off:off + 256])

    def write_sector(self, track, trkreg, sec, data):
        off = self._offset(*self.chs(track, trkreg, sec))
        if off is None or self.readonly:
            return False
        self.img[off:off + 256] = bytes(data[:256])
        return True


class RawDsk:
    """A raw sector image of a disk: 512 byte sectors (MSX .DSK) or 256 byte sectors (CoCo .DSK / .JVC), in track order, side 0 before
    side 1 on each track. MSX: the geometry comes from the boot sector's BPB when it is plausible, else from the size (720 KB = 80 tracks
    x 2 sides x 9 sectors, 360 KB = 80 x 1 x 9, 320 / 640 KB = 8 sectors per track). CoCo: 18 sectors of 256 bytes per track, 35 or 40
    tracks, one side up to 184320 bytes and two sides above; a JVC header (the bytes that make the size not a multiple of 256: sectors
    per track, sides, ...) is skipped."""

    def __init__(self, img, secsize=512):
        self.img = img
        self.secsize = secsize
        self.readonly = False
        self.ra_next = 0
        self.hdr = 0
        n = len(img)
        self.ok = False
        spt = heads = 0
        if secsize == 512:
            if n >= 512 and n % 512 == 0:
                bps = img[0x0B] | img[0x0C] << 8
                spt_b = img[0x18] | img[0x19] << 8
                heads_b = img[0x1A] | img[0x1B] << 8
                if bps == 512 and 1 <= spt_b <= 18 and heads_b in (1, 2) and (n // 512) % (spt_b * heads_b) == 0:
                    spt, heads = spt_b, heads_b
                else:
                    by_size = {368640: (9, 1), 737280: (9, 2), 327680: (8, 1), 655360: (8, 2), 184320: (9, 1), 163840: (8, 1)}
                    spt, heads = by_size.get(n, (9, 2))
        else:
            self.hdr = n % 256                                  # a JVC header
            body = n - self.hdr
            spt = img[0] if self.hdr >= 1 and 1 <= img[0] <= 36 else 18
            heads = img[1] if self.hdr >= 2 and img[1] in (1, 2) else (2 if body >= 322560 else 1)
            n = body
        if spt:
            tracks = (n // secsize) // (spt * heads)
            self.ok = (n // secsize) % (spt * heads) == 0 and 1 <= tracks <= 100
            self.spt, self.heads, self.tracks = spt, heads, tracks

    def _offset(self, track, side, trkreg, sec):
        if not self.ok or trkreg != track or track >= self.tracks or side >= self.heads or not 1 <= sec <= self.spt:
            return None
        return self.hdr + self.secsize * ((track * self.heads + side) * self.spt + sec - 1)

    def read_sector(self, track, side, trkreg, sec):
        off = self._offset(track, side, trkreg, sec)
        if off is None:
            return 0, None
        return DMK_FOUND, bytes(self.img[off:off + self.secsize])

    def write_sector(self, track, side, trkreg, sec, data, deleted=False):
        off = self._offset(track, side, trkreg, sec)
        if off is None or self.readonly:
            return False
        self.img[off:off + self.secsize] = bytes(data[:self.secsize]).ljust(self.secsize, bytes(1))
        return True

    def read_address(self, track, side):
        """(DMK_FOUND, C H R N CRC1 CRC2) of the next ID field of the track; N = 1 is 256 bytes, 2 is 512."""
        if not self.ok or track >= self.tracks or side >= self.heads:
            return 0, None
        self.ra_next = self.ra_next % self.spt + 1
        return DMK_FOUND, bytes([track, side, self.ra_next, 1 if self.secsize == 256 else 2, 0, 0])
