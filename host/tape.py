"""Tape images for the cassette recorder (rtl/bvf_tape.v): pulse lists in, a WAV of what the machine recorded out.

A tape is a list of entries (duration in microseconds, hold): the tape input starts low and toggles at the end of every entry, except
after an entry with hold set (a pause of constant level). The register word of an entry is  hold << 31 | duration  (duration < 2^20).

Formats:  .tap  ZX Spectrum (standard ROM blocks)          .cas  MSX (1200 baud FSK, blocks start at the 8 byte header)
          .cas / .c10 / .k7 raw bytes of a CoCo / MC-10 / Alice tape (1200 / 2400 Hz, least significant bit first)
          .cas (CP-300, the TRS-80's 500 baud) is told from the others by the machine
          .wav  PCM, any rate, mono or stereo (zero crossings; the web page converts WAVs itself and sends the finished entries)
          .tpl  entries as they are: little endian 32 bit words
"""
import array
import io
import struct
import wave

MAX_DUR = (1 << 20) - 1
MSX_HEADER = bytes([0x1F, 0xA6, 0xDE, 0xBA, 0xCC, 0x13, 0x7D, 0x74])


def _cycle(freq, out):
    half = 500000.0 / freq
    out.append(half)
    out.append(half)


def _pack(durs, tail_pause_us=0):
    """durations (floats, us) -> entry words; every duration is split to fit 20 bits (a long one becomes hold entries)."""
    words = array.array("I")
    for d in durs:
        d = max(1, int(round(d)))
        while d > MAX_DUR:
            words.append((1 << 31) | MAX_DUR)
            d -= MAX_DUR
        words.append(d)
    if tail_pause_us:
        d = int(tail_pause_us)
        while d > MAX_DUR:
            words.append((1 << 31) | MAX_DUR)
            d -= MAX_DUR
        words.append((1 << 31) | d)
    return words


def from_zx_tap(data):
    """The ROM loader's pulses: pilot 2168 T (8063 pulses for a header, 3223 for data), sync 667 + 735 T, bits 855 / 1710 T twice,
    one second of pause after a block. 1 T = 1 / 3.5 us."""
    t = 1.0 / 3.5
    out = []
    pos = 0
    while pos + 2 <= len(data):
        n = data[pos] | data[pos + 1] << 8
        blk = data[pos + 2:pos + 2 + n]
        pos += 2 + n
        out += [2168 * t] * (8063 if blk and blk[0] < 128 else 3223)
        out += [667 * t, 735 * t]
        for byte in blk:
            for k in range(7, -1, -1):
                p = (1710 if (byte >> k) & 1 else 855) * t
                out += [p, p]
        out.append(("pause", 1000000))                       # one second of silence after every block
    return _pack_holds(out)


def _pack_holds(out):
    """durations in us, or ("pause", us): a level held for that long (the chunks but the last carry the hold bit, so the level does
    not change inside a pause, and it toggles at its end)."""
    words = array.array("I")
    for d in out:
        if isinstance(d, tuple):
            n = int(d[1])
            while n > MAX_DUR:
                words.append((1 << 31) | MAX_DUR)
                n -= MAX_DUR
            words.append(n)
        else:
            words.extend(_pack([d]))
    return words


def _fsk_byte(b, out, one, zero, lsb_first=True, start=0, stop=0, stop_val=1):
    """one / zero are (frequency, cycles) of a bit 1 / 0."""
    bits = [0] * start + [(b >> k) & 1 for k in (range(8) if lsb_first else range(7, -1, -1))] + [stop_val] * stop
    for bit in bits:
        f, c = one if bit else zero
        for _ in range(c):
            _cycle(f, out)


def from_msx_cas(data):
    """1200 baud: a 0 is one cycle of 1200 Hz, a 1 is two cycles of 2400 Hz; start bit 0, 8 data bits (LSB first), two stop bits 1.
    Every block follows a header tone of 2400 Hz (long before a file's first block, short before the others)."""
    pos = [i for i in range(0, len(data) - 7, 8) if data[i:i + 8] == MSX_HEADER]
    if not pos:
        pos = [0]
        body = [data]
    else:
        body = [data[a + 8:b] for a, b in zip(pos, pos[1:] + [len(data)])]
    out = []
    for blk in body:
        file_start = blk[:1] in (b"\xd0", b"\xd3", b"\xea") and blk[1:10] == blk[1:2] * 9      # a file ID: ten equal bytes
        for _ in range(8000 if file_start else 3000):
            _cycle(2400, out)
        for b in blk:
            _fsk_byte(b, out, (2400, 2), (1200, 1), True, start=1, stop=2)
    return _pack_holds(out + [("pause", 500000)])


def from_coco_cas(data):
    """CoCo / MC-10 / Alice: bit 0 = one cycle of 1200 Hz, bit 1 = one cycle of 2400 Hz, least significant bit first (the file holds the
    leader, the sync byte and the blocks as they are on the tape)."""
    out = []
    for b in data:
        _fsk_byte(b, out, (2400, 1), (1200, 1), True)
    return _pack_holds([("pause", 500000)] + out + [("pause", 500000)])


def from_trs80_cas(data):
    """500 baud: a cell is 2 ms; a pulse (250 us high) opens it and another one 1 ms later holds a 1; most significant bit first."""
    out = []
    for b in data:
        for k in range(7, -1, -1):
            if (b >> k) & 1:
                out += [250, 750, 250, 750]
            else:
                out += [250, 1750]
    return _pack_holds([("pause", 500000)] + out + [("pause", 500000)])


def from_wav(data):
    """Zero crossings of the first channel with a hysteresis of 1/16 of the peak."""
    w = wave.open(io.BytesIO(data), "rb")
    n, width, ch, rate = w.getnframes(), w.getsampwidth(), w.getnchannels(), w.getframerate()
    raw = w.readframes(n)
    if width == 1:
        s = [b - 128 for b in raw[::ch]]
    elif width == 2:
        s = struct.unpack("<%dh" % (len(raw) // 2), raw)[::ch]
    else:
        raise ValueError("a WAV file of 8 or 16 bit samples")
    peak = max(max(s, default=0), -min(s, default=0)) or 1
    thr = peak // 16
    out = []
    level = s[0] > 0 if s else False
    last = 0
    for i, v in enumerate(s):
        if level and v < -thr:
            level = False
            out.append((i - last) * 1e6 / rate)
            last = i
        elif not level and v > thr:
            level = True
            out.append((i - last) * 1e6 / rate)
            last = i
    return _pack(out[1:] if out else [])


def from_entries(data):
    if len(data) % 4:
        raise ValueError("entries are 32 bit words")
    a = array.array("I")
    a.frombytes(data)
    return a


def load(name, data, machine=""):
    """Entries (array of 32 bit words) for a tape file, by its extension; the CAS format depends on the machine."""
    ext = name.lower().rsplit(".", 1)[-1] if "." in name else ""
    if ext == "tap":
        return from_zx_tap(data)
    if ext in ("tpl", "pulses"):
        return from_entries(data)
    if ext == "wav":
        return from_wav(data)
    if ext in ("cas", "c10", "k7", "bin"):
        if machine == "msx1":
            return from_msx_cas(data)
        if machine == "cp300":
            return from_trs80_cas(data)
        return from_coco_cas(data)
    raise ValueError("tape files: .tap (ZX Spectrum), .cas / .c10 / .k7, .wav, or finished pulse entries (.tpl)")


def duration_us(words):
    return sum(w & MAX_DUR for w in words)


def to_wav(records, three_level=False, rate=22050):
    """records: (level, dt_us) as the recorder stored them (the level held *after* the change, dt since the previous change).
    8 bit mono WAV; three_level: the CP-300's 2 bit output (01 high, 10 low, 00 and 11 the middle)."""
    amp = {0: 128, 1: 128 + 100, 2: 128 - 100, 3: 128} if three_level else {0: 128 - 100, 1: 128 + 100, 2: 128 + 100, 3: 128 + 100}
    level = 0
    t = 0.0
    samples = bytearray()
    for lv, dt in records:
        n = int(round(dt * rate / 1e6))
        samples += bytes([amp[level]]) * n
        level = lv
        t += dt
    samples += bytes([amp[level]]) * (rate // 10)
    buf = io.BytesIO()
    w = wave.open(buf, "wb")
    w.setnchannels(1)
    w.setsampwidth(1)
    w.setframerate(rate)
    w.writeframes(bytes(samples))
    w.close()
    return buf.getvalue()
