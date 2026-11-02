#!/usr/bin/env python3
"""Convert TRS-80 disk images (JV1, JV3, HFE) to DMK, the format the CP-300 FPGA reads.

    python tools/dsk2dmk.py in.img out.dsk [--format auto|jv1|jv3|dmk|hfe]
    python tools/dsk2dmk.py indir outdir [--force]     convert a whole folder (8.3 names + INDEX.TXT)

The FPGA's IO controller uses DMK images directly (David Keil's format, as xtrs, TRS80GP, HxC and
FreHD use it), with real sector IDs, FM/MFM tracks, deleted data marks and CRC errors. A DMK input is
copied unchanged. JV1 and JV3 disks, and HFE bit-stream dumps (decoded here, FM and MFM), are
rebuilt as DMK tracks: ID fields, data fields and CRCs as the controller would have written them.

Limits: sectors of any size are kept, but the controller only reads 256-byte sectors; one track
holds up to 64 sectors and 6400 bytes (0x1900, the usual 5.25" DMK track length).

Formats read:
  JV1  no header, 256-byte sectors, 10 per track, single sided, single density
  JV3  Jeff Vavasour's, https://www.tim-mann.org/trs80/dskspec.html
  DMK  David Keil's, header 16 bytes + per track a 128-byte IDAM table (offsets with bit 15 = DD)
  HFE  HxC Floppy Emulator v1 ("HXCPICFE"): the bit cells of every track
"""
import argparse
import os
import re
import struct
import sys

NL = chr(10)
TLEN = 0x1900          # bytes per track in the DMK files written here


class Sector:
    def __init__(self, data, dd=True, dam=0xFB, bad_crc=False, c=None, h=None):
        self.c, self.h = c, h        # cylinder and head numbers in the ID field (None: as the position)
        self.data = bytes(data)
        self.dd = dd                 # double density (MFM); False = single density (FM)
        self.dam = dam               # data address mark: FB normal, F8 deleted, FA/F9 user
        self.bad_crc = bad_crc


class Disk:
    """What the readers collect: sectors[(track, side, id)] = Sector, in the order found."""

    def __init__(self):
        self.sectors = {}
        self.sides = 1
        self.tracks = 0
        self.warnings = []
        self.dups = set()            # (track, side, id) found more than once (copy protection)

    def add(self, track, side, sid, data, dd=True, dam=0xFB, bad_crc=False, c=None, h=None):
        if (track, side, sid) in self.sectors:
            self.dups.add((track, side, sid))
        self.sectors[(track, side, sid)] = Sector(data, dd, dam, bad_crc, c, h)
        self.sides = max(self.sides, side + 1)
        self.tracks = max(self.tracks, track + 1)


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


# ---- JV1 ----------------------------------------------------------------

def read_jv1(blob):
    d = Disk()
    for n in range(len(blob) // 256):
        t = n // 10
        d.add(t, 0, n % 10, blob[n * 256:(n + 1) * 256], dd=False, dam=0xFA if t == 17 else 0xFB)
    return d


# ---- JV3 ----------------------------------------------------------------

JV3_ENTRIES = 2901
JV3_HEADER = JV3_ENTRIES * 3 + 1
JV3_DAM_SD = {0x00: 0xFB, 0x20: 0xFA, 0x40: 0xF9, 0x60: 0xF8}
JV3_DAM_DD = {0x00: 0xFB, 0x20: 0xF8, 0x40: 0xFB, 0x60: 0xFB}


def jv3_size(flags, free):
    code = flags & 3
    return 128 << (code ^ 2 if free else code ^ 1)


def jv3_looks_valid(blob):
    if len(blob) < JV3_HEADER:
        return False
    pos = JV3_HEADER
    used = 0
    for i in range(JV3_ENTRIES):
        t, s, f = blob[i * 3:i * 3 + 3]
        if t == 0xFF and s == 0xFF:
            break
        pos += jv3_size(f, False)
        used += 1
        if pos > len(blob):
            return False
    return used > 0


def read_jv3(blob):
    d = Disk()
    base = 0
    while base + JV3_HEADER <= len(blob):
        pos = base + JV3_HEADER
        used = 0
        for i in range(JV3_ENTRIES):
            t, s, f = blob[base + i * 3:base + i * 3 + 3]
            free = (t == 0xFF and s == 0xFF)
            size = jv3_size(f, free)
            if pos + size > len(blob):
                pos = len(blob)
                break
            if not free:
                used += 1
                dd = bool(f & 0x80)
                dam = (JV3_DAM_DD if dd else JV3_DAM_SD)[f & 0x60]
                d.add(t, (f >> 4) & 1, s, blob[pos:pos + size], dd, dam, bool(f & 0x08))
            pos += size
        base = pos            # a second header block follows the data of the first one
        if used == 0:
            break
    return d


# ---- DMK ----------------------------------------------------------------

def dmk_looks_valid(blob):
    if len(blob) < 16 + 128:
        return False
    ntracks = blob[1]
    tlen = blob[2] | (blob[3] << 8)
    if blob[0] not in (0x00, 0xFF) or not 1 <= ntracks <= 100 or tlen < 128 + 16 or tlen > 0x2940:
        return False
    if blob[12:16] != bytes(4):
        return False
    first = struct.unpack_from("<H", blob, 16)[0] & 0x3FFF
    return 128 <= first < tlen


def read_dmk(blob):
    d = Disk()
    ntracks = blob[1]
    tlen = blob[2] | (blob[3] << 8)
    flags = blob[4]
    sides = 1 if flags & 0x10 else 2
    doubled = not (flags & 0xC0)     # single density bytes are stored twice
    for t in range(ntracks):
        for s in range(sides):
            off = 16 + (t * sides + s) * tlen
            trk = blob[off:off + tlen]
            if len(trk) < tlen:
                if len(trk) >= 128:
                    d.warnings.append(f"track {t} side {s} is truncated")
                    trk = trk + bytes(tlen - len(trk))
                else:
                    d.warnings.append(f"the file ends before track {t} side {s}")
                    return d
            ptrs = [struct.unpack_from("<H", trk, 2 * i)[0] for i in range(64)]
            for i, p in enumerate(ptrs):
                if p == 0:
                    break
                dd = bool(p & 0x8000)
                pos = p & 0x3FFF
                step = 2 if (doubled and not dd) else 1
                nxt = None
                for q in ptrs[i + 1:]:
                    if q:
                        nxt = q & 0x3FFF
                        break
                limit = nxt if nxt else tlen

                def at(n):
                    k = pos + n * step
                    return trk[k] if k < tlen else None

                if at(0) != 0xFE:
                    d.warnings.append(f"track {t} side {s}: IDAM {i} does not start with FE")
                    continue
                c, h, r, n = at(1), at(2), at(3), at(4)
                if None in (c, h, r, n) or n > 3:
                    d.warnings.append(f"track {t} side {s}: bad ID field {i}")
                    continue
                size = 128 << n
                dam = None
                for k in range(7, 90):
                    if pos + k * step >= limit:
                        break
                    if at(k) in (0xF8, 0xF9, 0xFA, 0xFB):
                        dam = k
                        break
                if dam is None:
                    d.warnings.append(f"track {t} side {s} sector {r}: no data mark")
                    continue
                vals = [at(dam + 1 + j) for j in range(size + 2)]
                data = bytes(0 if v is None else v for v in vals[:size])
                pre = bytes([0xA1] * 3) if dd else b""
                bad = crc16(pre + bytes([at(dam)]) + data) != ((vals[size] or 0) << 8 | (vals[size + 1] or 0))
                if c != t:
                    d.warnings.append(f"track {t} side {s}: sector ID says track {c}")
                d.add(t, s, r, data, dd, at(dam), bad, c, h)
    return d


# ---- HFE (HxC Floppy Emulator, v1) ----------------------------------------

_BITS = [format(b, "08b")[::-1] for b in range(256)]       # HFE stores the first cell in bit 0


def fm_word(data, clock=0xC7):
    return "".join(f"{(clock >> i) & 1}{(data >> i) & 1}" for i in range(7, -1, -1))


_FM_ID = fm_word(0xFE)
_FM_DAM = {m: fm_word(m) for m in (0xF8, 0xF9, 0xFA, 0xFB)}
_MFM_SYNC = "0100010010001001" * 3                         # A1 A1 A1 with the missing clock


def decode_cells(cells, start, count):
    """Decode `count` data bytes starting at cell index `start` (data bits are every second cell)."""
    out = bytearray()
    for k in range(count):
        w = cells[start + 16 * k + 1:start + 16 * k + 16:2]
        if len(w) < 8:
            return None
        out.append(int(w, 2))
    return bytes(out)


def hfe_track_events(cells):
    """[(position, 'id'|'dam', fm, mark, first data cell)] sorted by position."""
    ev = []
    for m in re.finditer("(?=" + _FM_ID + ")", cells):
        ev.append((m.start(), "id", True, 0xFE, m.start() + 16))
    for mark, pat in _FM_DAM.items():
        for m in re.finditer("(?=" + pat + ")", cells):
            ev.append((m.start(), "dam", True, mark, m.start() + 16))
    for m in re.finditer("(?=" + _MFM_SYNC + ")", cells):
        e = m.start() + 48
        mk = decode_cells(cells, e, 1)
        if mk and mk[0] == 0xFE:
            ev.append((m.start(), "id", False, 0xFE, e + 16))
        elif mk and mk[0] in (0xF8, 0xF9, 0xFA, 0xFB):
            ev.append((m.start(), "dam", False, mk[0], e + 16))
    ev.sort()
    return ev


def read_hfe(blob):
    d = Disk()
    if blob[:8] != b"HXCPICFE":
        sys.exit("error: not an HFE v1 file (HFE v3 is not supported)")
    ntracks, nsides = blob[9], blob[10]
    lut = struct.unpack_from("<H", blob, 18)[0] * 512
    for t in range(ntracks):
        off, tlen = struct.unpack_from("<HH", blob, lut + 4 * t)
        off *= 512
        raw = blob[off:off + ((tlen + 511) // 512) * 512]
        for s in range(nsides):
            side = b"".join(raw[i + s * 256:i + s * 256 + 256] for i in range(0, len(raw), 512))[:tlen // 2]
            cells = "".join(_BITS[b] for b in side)
            ev = hfe_track_events(cells)
            for i, (pos, kind, fm, mark, data0) in enumerate(ev):
                if kind != "id":
                    continue
                idf = decode_cells(cells, data0, 6)
                if idf is None:
                    continue
                c, h, r, n = idf[:4]
                if n > 3:
                    continue
                size = 128 << n
                nxt = next((e for e in ev[i + 1:] if e[1] == "id"), None)
                limit = nxt[0] if nxt else len(cells)
                dam = next((e for e in ev[i + 1:] if e[1] == "dam" and e[2] == fm and e[0] < limit
                            and e[0] - data0 < 16 * 80), None)
                if dam is None:
                    d.warnings.append(f"track {t} side {s} sector {r}: no data mark")
                    continue
                data = decode_cells(cells, dam[4], size + 2)
                if data is None:
                    d.warnings.append(f"track {t} side {s} sector {r}: data field cut short")
                    continue
                pre = bytes([0xA1] * 3) if not fm else b""
                bad = crc16(pre + bytes([dam[3]]) + data[:size]) != (data[size] << 8 | data[size + 1])
                if c != t:
                    d.warnings.append(f"track {t} side {s}: sector ID says track {c}")
                d.add(t, s, r, data[:size], not fm, dam[3], bad, c, h)
    return d


# ---- DMK writer -----------------------------------------------------------

def build_track(sectors, t, s):
    """One DMK track (TLEN bytes) from [(id, Sector)] in disk order; single density sectors are
    written with every byte twice, as the DMK header (flags 0) says."""
    trk = bytearray(b"\x4E" * TLEN)
    trk[0:128] = bytes(128)
    pos = 128
    ptrs = []

    def put(bs, dd):
        nonlocal pos
        for b in bs:
            for _ in range(1 if dd else 2):
                if pos >= TLEN:
                    sys.exit(f"error: track {t} side {s} does not fit in {TLEN} bytes")
                trk[pos] = b
                pos += 1

    if sectors:
        first_dd = sectors[0][1].dd
        put(b"\x4E" * 40 if first_dd else b"\xFF" * 16, first_dd)
    for sid, sec in sectors:
        dd = sec.dd
        gap = b"\x4E" if dd else b"\xFF"
        size = len(sec.data)
        if size not in (128, 256, 512, 1024):
            continue
        n = {128: 0, 256: 1, 512: 2, 1024: 3}[size]
        put(bytes(12 if dd else 6), dd)
        if dd:
            put(b"\xA1\xA1\xA1", dd)
        if len(ptrs) >= 64:
            sys.exit(f"error: more than 64 sectors on track {t} side {s}")
        ptrs.append(pos | (0x8000 if dd else 0))
        idf = bytes([0xFE, t if sec.c is None else sec.c, s if sec.h is None else sec.h, sid, n])
        crc = crc16((b"\xA1\xA1\xA1" if dd else b"") + idf)
        put(idf + struct.pack(">H", crc), dd)
        put(gap * (22 if dd else 11), dd)
        put(bytes(12 if dd else 6), dd)
        if dd:
            put(b"\xA1\xA1\xA1", dd)
        crc = crc16((b"\xA1\xA1\xA1" if dd else b"") + bytes([sec.dam]) + sec.data)
        if sec.bad_crc:
            crc ^= 0xFFFF
        put(bytes([sec.dam]) + sec.data + struct.pack(">H", crc), dd)
        put(gap * (24 if dd else 16), dd)
    for i, p in enumerate(ptrs):
        struct.pack_into("<H", trk, 2 * i, p)
    return bytes(trk)


def write_dmk(disk):
    sides = disk.sides
    out = bytearray(16)
    out[1] = disk.tracks
    out[2], out[3] = TLEN & 255, TLEN >> 8
    if sides == 1:
        out[4] = 0x10
    for t in range(disk.tracks):
        for s in range(sides):
            secs = []
            for (tt, ss, sid), sec in disk.sectors.items():
                if (tt, ss) == (t, s):
                    secs.append((sid, sec))
            out += build_track(secs, t, s)
    return bytes(out)


# ---- conversion ---------------------------------------------------------

def detect(blob):
    if blob[:8] == b"HXCPICFE":
        return "hfe"
    if dmk_looks_valid(blob):
        return "dmk"
    if jv3_looks_valid(blob):
        return "jv3"
    if len(blob) % 2560 == 0 and len(blob) > 0:
        return "jv1"
    sys.exit("error: cannot tell the format (use --format)")


def convert(blob, fmt="auto"):
    if fmt == "auto":
        fmt = detect(blob)
    disk = {"jv1": read_jv1, "jv3": read_jv3, "dmk": read_dmk, "hfe": read_hfe}[fmt](blob)
    if not disk.sectors:
        sys.exit("error: no sectors found")
    n256 = sum(1 for s in disk.sectors.values() if len(s.data) == 256)
    info = {"format": fmt, "tracks": disk.tracks, "sides": disk.sides, "sectors": len(disk.sectors),
            "other_size": len(disk.sectors) - n256, "crc_errors": sum(s.bad_crc for s in disk.sectors.values()),
            "warnings": disk.warnings,
            "first_id": min(k[2] for k in disk.sectors)}
    return (blob if fmt == "dmk" else write_dmk(disk)), info


EXTS = (".dsk", ".dmk", ".hfe", ".jv1", ".jv3")


def short_name(stem, taken):
    """8.3 name that survives on the SD card (the firmware does not read long names)."""
    m = re.match(r"DSKA(\d{4})_(.*)", stem.upper())
    if m:
        body = re.sub(r"[^A-Z0-9]", "", m.group(2)) or "DISK"
        base = body[:5] + m.group(1)[1:]
    else:
        base = (re.sub(r"[^A-Z0-9]", "", stem.upper()) or "DISK")[:8]
    name, n = base, 1
    while name + ".DSK" in taken:
        n += 1
        name = base[:8 - len(str(n))] + str(n)
    return name + ".DSK"


def batch(indir, outdir, force=False):
    """force: reuse the names of files already in outdir (a re-run of the same conversion)."""
    os.makedirs(outdir, exist_ok=True)
    files = sorted(f for f in os.listdir(indir) if f.lower().endswith(EXTS))
    # the same disk as DMK/DSK and as HFE: use the DMK
    rank = {".dmk": 0, ".dsk": 0, ".jv3": 0, ".jv1": 0, ".hfe": 1}
    best = {}
    for f in files:
        stem, ext = os.path.splitext(f)
        k = stem.upper()
        if k not in best or rank[ext.lower()] < rank[os.path.splitext(best[k])[1].lower()]:
            best[k] = f
    taken = set() if force else {n.upper() for n in os.listdir(outdir)}
    lines, seen, ok = [], {}, 0
    for f in files:
        stem = os.path.splitext(f)[0]
        if best[stem.upper()] != f:
            lines.append(f"{f:40s} skipped: the same disk is converted from {best[stem.upper()]}")
            continue
        try:
            dmk, info = convert(open(os.path.join(indir, f), "rb").read())
        except SystemExit as e:
            lines.append(f"{f:40s} FAILED: {e}")
            print(f"{f}: FAILED: {e}")
            continue
        out = short_name(stem, taken)
        taken.add(out)
        open(os.path.join(outdir, out), "wb").write(dmk)
        ok += 1
        same = seen.setdefault(hash(dmk), out)
        extra = []
        if same != out:
            extra.append(f"identical to {same}")
        if info["other_size"]:
            extra.append(f"{info['other_size']} sectors not 256 bytes")
        if info["crc_errors"]:
            extra.append(f"{info['crc_errors']} CRC errors")
        if info["warnings"]:
            extra.append(f"{len(info['warnings'])} warnings, first: {info['warnings'][0]}")
        line = (f"{out:13s} <- {f:36s} {info['format'].upper()} {info['tracks']:2d} tracks "
                f"{info['sides']} side(s) {info['sectors']:4d} sectors  " + "; ".join(extra))
        lines.append(line.rstrip())
        print(line.rstrip())
    with open(os.path.join(outdir, "INDEX.TXT"), "w") as fh:
        fh.write("Converted by tools/dsk2dmk.py: DMK images for the CP-300 FPGA." + NL)
        fh.write("Copy the *.DSK files to /CP300 on the SD card." + NL + NL)
        fh.write(NL.join(lines) + NL)
    print(f"{ok} images written to {outdir}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--format", choices=["auto", "jv1", "jv3", "dmk", "hfe"], default="auto")
    ap.add_argument("--force", action="store_true", help="folder mode: overwrite files of the same name in the output folder")
    a = ap.parse_args()
    if os.path.isdir(a.input):
        batch(a.input, a.output, a.force)
        return
    dmk, info = convert(open(a.input, "rb").read(), a.format)
    open(a.output, "wb").write(dmk)
    print(f"{info['format'].upper()}: {info['tracks']} tracks, {info['sides']} side(s), {info['sectors']} sectors "
          f"({info['other_size']} not 256 bytes, {info['crc_errors']} with CRC errors); {len(dmk)} bytes -> {a.output}")
    for w in info["warnings"][:20]:
        print("warning:", w)
    if len(info["warnings"]) > 20:
        print(f"warning: {len(info['warnings']) - 20} more")


if __name__ == "__main__":
    main()
