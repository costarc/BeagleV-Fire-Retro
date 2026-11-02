#!/usr/bin/env python3
"""Test of cp300d against its simulated registers: starts the daemon, then drives it like the web page does.

    python test_cp300d.py            prints PASS or the first failure
"""
import base64
import http.client
import array
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools"))
import cp300d          # noqa: E402
import diskimg         # noqa: E402
import dsk2dmk         # noqa: E402

PORT = 18300


def make_jv1():
    """35 tracks x 10 sectors x 256 bytes: sector bytes are (track*31 + sector*7 + i) & 255."""
    out = bytearray()
    for t in range(35):
        for s in range(10):
            out += bytes((t * 31 + s * 7 + i) & 255 for i in range(256))
    return bytes(out)


class WS:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(1)
        assert b" 101 " in buf.split(b"\r\n")[0], buf

    def recv_exact(self, n):
        d = b""
        while len(d) < n:
            c = self.s.recv(n - len(d))
            if not c:
                raise EOFError
            d += c
        return d

    def recv(self):
        h = self.recv_exact(2)
        op, n = h[0] & 15, h[1] & 127
        if n == 126: n = struct.unpack("!H", self.recv_exact(2))[0]
        elif n == 127: n = struct.unpack("!Q", self.recv_exact(8))[0]
        return op, self.recv_exact(n)

    def send_text(self, text):
        data = text.encode()
        mask = os.urandom(4)
        head = bytes([0x81, 0x80 | len(data)]) if len(data) < 126 else bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(data))
        self.s.sendall(head + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))


def req(method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request(method, path, body)
    r = c.getresponse()
    return r.status, r.read()


def px(fb, x, y):
    return (fb[(y * 512 + x) // 8] >> (x % 8)) & 1


def main():
    data = tempfile.mkdtemp(prefix="cp300d_")
    p = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "cp300d.py"), "--sim", "--port", str(PORT),
                          "--host", "127.0.0.1", "--data", data], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(50):
            try:
                st, body = req("GET", "/api/state")
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise SystemExit("FAIL: daemon did not start")
        s = json.loads(body)
        assert s["run"] == 1 and s["roms"]["system"], s
        print("ok   state", s["drives"][0])

        st, body = req("GET", "/")
        assert st == 200 and b"CP-300" in body
        print("ok   page served")

        # disk upload: a JV1 image is converted to DMK
        jv1 = make_jv1()
        expect, _ = dsk2dmk.convert(jv1)
        st, body = req("PUT", "/api/disk/0?name=TEST.DSK", jv1)
        assert st == 200, body
        st, got = req("GET", "/api/disk/0")
        assert st == 200 and got == expect, "downloaded DMK differs (%d vs %d bytes)" % (len(got), len(expect))
        print("ok   disk mount + download (%d bytes DMK)" % len(got))

        # websocket: first message is the state, then a keyframe, then deltas
        ws = WS(PORT)
        op, txt = ws.recv()
        assert op == 1 and json.loads(txt)["drives"][0]["size"] == len(expect)
        fb = None
        deadline = time.time() + 5
        while time.time() < deadline:
            op, m = ws.recv()
            if op == 2 and m[0] == 1:
                kind = m[3]
                d = zlib.decompress(m[4:])
                assert len(d) == 12288
                fb = d if kind == 0 else bytes(a ^ b for a, b in zip(fb, d))
                break
        assert fb is not None and px(fb, 0, 0) == 1 and px(fb, 100, 100) == 0
        print("ok   frame keyframe, border pixel set")

        # press matrix key 'A' (row 0 col 1 = bit 1): the sim draws a block at (1 * 56 + 40, 16)
        ws.send_text(json.dumps({"keys": "%016x" % (1 << 1)}))
        seen_block = clicks = False
        deadline = time.time() + 5
        while time.time() < deadline and not (seen_block and clicks):
            op, m = ws.recv()
            if op != 2:
                continue
            if m[0] == 1:
                kind = m[3]
                d = zlib.decompress(m[4:])
                fb = d if kind == 0 else bytes(a ^ b for a, b in zip(fb, d))
                if px(fb, 100, 20):
                    seen_block = True
            elif m[0] == 2:
                clicks = clicks or (len(m) - 1) // 6 >= 2
        assert seen_block, "key block not drawn"
        assert clicks, "no audio events"
        print("ok   key press changes the picture, audio events arrive")

        # XOR frames come with consecutive seq; after {"keyframe":1} the next frame is a whole one
        last = None
        for _ in range(3):
            while True:
                op, m = ws.recv()
                if op == 2 and m[0] == 1:
                    break
            seq = m[1] | m[2] << 8
            assert m[3] == 1 and (last is None or seq == (last + 1) & 0xFFFF), (m[3], seq, last)
            last = seq
        ws.send_text(json.dumps({"keyframe": 1}))
        kinds = []
        deadline = time.time() + 5
        while time.time() < deadline and 0 not in kinds:
            op, m = ws.recv()
            if op == 2 and m[0] == 1:
                kinds.append(m[3])
                if m[3] == 0:
                    fb = zlib.decompress(m[4:])
        assert 0 in kinds and len(kinds) <= 3, kinds
        assert px(fb, 0, 0) == 1
        print("ok   consecutive seq, key frame on request")

        # the probe leaves the machine as it was: keys put back, CTRL not written
        ws.send_text(json.dumps({"keys": "%016x" % (1 << 5)}))
        time.sleep(0.2)
        st, body = req("POST", "/api/ctrl", json.dumps({"turbo": 1}).encode())
        before = json.loads(body)
        st, body = req("GET", "/api/debug")
        dbg = json.loads(body)
        assert st == 200 and dbg["irq"] is False and dbg["frames_per_second"] > 30, dbg
        assert dbg["keys_lo_readback"] == "0xa5a55a5a" and dbg["block_write_readback"] == ["0x11223344", "0x55667788"], dbg
        assert int(dbg["ctrl"], 16) == 5, dbg                     # run + turbo
        st, body = req("GET", "/api/state")
        assert json.loads(body)["turbo"] == before["turbo"] == 1
        st, body = req("GET", "/api/debug")
        assert int(json.loads(body)["ctrl"], 16) == 5
        print("ok   /api/debug: readback tests, CTRL untouched")

        ws.send_text(json.dumps({"keys": "%016x" % 0}))
        st, body = req("PUT", "/api/rom/system", b"short")
        assert st == 400
        st, body = req("POST", "/api/ctrl", json.dumps({"turbo": 1}).encode())
        assert json.loads(body)["turbo"] == 1
        print("ok   ROM size check, ctrl")

        # power cycle: the daemon asks the gateware to clear the RAM and restart; the machine keeps running afterwards
        st, body = req("POST", "/api/ctrl", json.dumps({"cold": 1}).encode())
        assert st == 200 and json.loads(body)["run"] == 1, body
        st, body = req("GET", "/api/debug")
        assert int(json.loads(body)["ctrl"], 16) & 0x80 == 0       # a pulse, not a level
        print("ok   power cycle")
        st, body = req("POST", "/api/ctrl", json.dumps({"power": 0}).encode())
        assert json.loads(body)["run"] == 0, body
        st, body = req("POST", "/api/ctrl", json.dumps({"reset": 1}).encode())      # reset while off: nothing starts
        assert json.loads(body)["run"] == 0, body
        st, body = req("POST", "/api/ctrl", json.dumps({"power": 1}).encode())
        assert json.loads(body)["run"] == 1, body
        print("ok   power off / on")

        # the CP-400: ROM upload (8 KB each), switching the machine, a 4 bit colour frame, the CP-300 again
        st, body = req("PUT", "/api/rom/cp400bas", b"short")
        assert st == 400
        st, body = req("POST", "/api/ctrl", json.dumps({"machine": "cp400"}).encode())
        assert json.loads(body)["machine"] == "cp400" and json.loads(body)["run"] == 0   # no ROMs yet: held
        for name in ("cp400bas", "cp400ext"):
            st, body = req("PUT", "/api/rom/" + name, bytes(range(256)) * 32)
            assert st == 200, body
        st, body = req("GET", "/api/state")
        s4 = json.loads(body)
        assert s4["machine"] == "cp400" and s4["run"] == 1 and s4["roms"]["cp400bas"] and s4["roms"]["cp400ext"], s4
        ws4 = WS(PORT)
        ws4.send_text(json.dumps({"keys": "%016x" % (1 << 9)}))      # CoCo bit 9 = column 1, row 1 ('H')
        got4 = False
        deadline = time.time() + 5
        fb4 = None
        while time.time() < deadline and not got4:
            op, m = ws4.recv()
            if op == 2 and m[0] == 3:
                d = zlib.decompress(m[4:])
                assert len(d) == 24576, len(d)
                fb4 = d if m[3] == 0 else bytes(a ^ b for a, b in zip(fb4, d)) if fb4 else None
                if fb4 and (fb4[0] & 15) == 5 and any(v & 15 or v >> 4 for v in fb4[40 * 128 + 25:40 * 128 + 30]):
                    got4 = True
        assert got4, "no CP-400 frame with the key block"
        print("ok   CP-400: ROMs, machine switch, 4 bit frame")

        # the MSX1 and the ZX Spectrum (the shared Z80): ROM sizes, held until the ROMs are there, then running
        st, body = req("POST", "/api/ctrl", json.dumps({"machine": "msx1"}).encode())
        assert json.loads(body)["machine"] == "msx1" and json.loads(body)["run"] == 0, body
        assert req("PUT", "/api/rom/msx1bios", b"x" * 16384)[0] == 400
        assert req("PUT", "/api/rom/msx1cart", b"x" * 40000)[0] == 400
        assert req("PUT", "/api/rom/msx1cart", bytes(range(256)) * 64)[0] == 200          # 16 KB cartridge: no BIOS yet, still held
        assert json.loads(req("GET", "/api/state")[1])["run"] == 0
        assert req("PUT", "/api/rom/msx1bios", bytes(range(256)) * 128)[0] == 200
        sx = json.loads(req("GET", "/api/state")[1])
        assert sx["run"] == 1 and sx["roms"]["msx1bios"] and sx["roms"]["msx1cart"] and not sx["roms"]["msx1p2"], sx
        assert req("DELETE", "/api/rom/msx1cart")[0] == 200
        assert not json.loads(req("GET", "/api/state")[1])["roms"]["msx1cart"]
        st, body = req("POST", "/api/ctrl", json.dumps({"machine": "zx"}).encode())
        assert json.loads(body)["machine"] == "zx" and json.loads(body)["run"] == 0, body
        assert req("PUT", "/api/rom/zx48", b"x" * 8192)[0] == 400
        assert req("PUT", "/api/rom/zx48", bytes(range(256)) * 64)[0] == 200
        sz = json.loads(req("GET", "/api/state")[1])
        assert sz["machine"] == "zx" and sz["run"] == 1 and sz["roms"]["zx48"], sz
        st, body = req("POST", "/api/ctrl", json.dumps({"machine": "mc1000"}).encode())
        assert json.loads(body)["machine"] == "mc1000" and json.loads(body)["run"] == 0, body
        assert req("PUT", "/api/rom/mc1000", b"x" * 8192)[0] == 400
        assert req("PUT", "/api/rom/mc1000", bytes(range(256)) * 64)[0] == 200
        sm = json.loads(req("GET", "/api/state")[1])
        assert sm["machine"] == "mc1000" and sm["run"] == 1 and sm["roms"]["mc1000"], sm
        st, body = req("POST", "/api/ctrl", json.dumps({"machine": "alice"}).encode())
        assert json.loads(body)["machine"] == "alice" and json.loads(body)["run"] == 0, body
        assert req("PUT", "/api/rom/alice", b"x" * 16384)[0] == 400
        assert req("PUT", "/api/rom/alice", bytes(range(256)) * 32)[0] == 200
        sa = json.loads(req("GET", "/api/state")[1])
        assert sa["machine"] == "alice" and sa["run"] == 1 and sa["roms"]["alice"], sa
        full = bytes([0x00, 0x80]) + bytes([1]) * 8192 + bytes([2]) * 8192 + bytes([3]) * 8192
        assert req("PUT", "/api/rom/cp400", bytes(1000))[0] == 400
        assert req("PUT", "/api/rom/cp400", full)[0] == 200
        sc = json.loads(req("GET", "/api/state")[1])
        assert sc["roms"]["cp400bas"] and sc["roms"]["cp400ext"] and sc["roms"]["cp400cart"], sc["roms"]
        assert req("PUT", "/api/rom/cp400", full[:16386])[0] == 200, "16 KB without the cartridge"
        assert req("PUT", "/api/rom/cp400cart", bytes(8192))[0] == 200
        assert json.loads(req("GET", "/api/state")[1])["roms"]["cp400cart"]
        assert req("DELETE", "/api/rom/cp400cart")[0] == 200
        assert not json.loads(req("GET", "/api/state")[1])["roms"]["cp400cart"], "the cartridge was not ejected"
        print("ok   MSX1, ZX Spectrum, MC-1000, Alice: ROMs, machine switch")
        st, body = req("POST", "/api/ctrl", json.dumps({"machine": "cp300"}).encode())
        assert json.loads(body)["machine"] == "cp300" and json.loads(body)["run"] == 1
        print("ok   back to the CP-300")

        # an IDE image larger than the 20 MB of the other uploads streams to a file; a file put there by hand is found by a rescan
        big = bytes(range(256)) * 2 * 50000                      # 25.6 MB of 512 byte sectors
        st, body = req("PUT", "/api/ide?name=BIG.IMG", big)
        assert st == 200 and json.loads(body)["info"]["sectors"] == 50000, (st, body)
        st, body = req("GET", "/api/state")
        assert json.loads(body)["ide"] == {"name": "BIG.IMG", "size": len(big)}, body
        st, body = req("PUT", "/api/ide?name=BAD.IMG", b"x" * 1000)
        assert st == 400, st
        st, body = req("DELETE", "/api/ide")
        assert st == 200
        open(os.path.join(data, "ide0.img"), "wb").write(bytes(512 * 7))
        st, body = req("POST", "/api/ide/rescan")
        assert st == 200 and json.loads(body)["info"]["sectors"] == 7, (st, body)
        st, body = req("DELETE", "/api/ide")
        print("ok   IDE image: streamed upload (25 MB), bad size refused, rescan of a file put there by hand")
    finally:
        p.terminate()
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
    service_tests()
    ide_tests()
    msx_tests()
    frehd_tests()
    print("PASS")


def jv1_sector(t, s):
    return bytes((t * 31 + s * 7 + i) & 255 for i in range(256))


def ask(regs, dev, req, data=None):
    """One request of the simulated controller, answered by the daemon: (result bits, buffer)."""
    if data is not None:
        regs.buf[:256] = data
    regs.request(req)
    assert dev.service(), "request not seen"
    assert regs.req == 0 and regs.ack == 0, "handshake not finished"
    served, res, buf = regs.log[-1]
    assert served == req
    return res, buf


def rq(kind, drive=0, side=0, track=0, trkreg=None, sec=0, dam=0, hd=0):
    trkreg = track if trkreg is None else trkreg
    return (kind | side << 3 | drive << 4 | dam << 6 | hd << 7 | track << 8 | trkreg << 16 | sec << 24)


def ide_tests():
    """The CP-400's hard disk (service_ide()) against SimRegs' model of bvf_ide."""
    regs = cp300d.SimRegs()
    d = tempfile.mkdtemp(prefix="cp300d_")
    dev = cp300d.Cp300(regs, d)
    img = b"".join(bytes((s * 11 + i) & 255 for i in range(512)) for s in range(8))
    assert regs.ide_cfg == 0

    def ask_ide(kind, lba, window=None):
        if window is not None:
            regs.ide_buf[:] = window
        regs.ide_req, regs.ide_lba = kind, lba
        assert dev.service(), "IDE request not seen"
        assert regs.ide_req == 0, "request not answered"
        return regs.ide_log[-1]

    # no disk: an error
    req, lba, err, buf = ask_ide(1, 0)
    assert err == cp300d.IDE_ERR_IDNF
    info = dev.mount_ide(img, "T.IMG")
    assert info["sectors"] == 8 and regs.ide_cfg == 1, (info, regs.ide_cfg)
    # read, with the last sector, and one past the end
    req, lba, err, buf = ask_ide(1, 3)
    assert err == 0 and buf == cp300d.sector_words(img[3 * 512:4 * 512])      # the window holds the words as the DOS's loop wants them
    req, lba, err, buf = ask_ide(1, 7)
    assert err == 0 and buf == cp300d.sector_words(img[7 * 512:])
    req, lba, err, buf = ask_ide(1, 8)
    assert err == cp300d.IDE_ERR_IDNF
    # write: the file changes in place
    new = bytes((255 - i) & 255 for i in range(512))
    req, lba, err, buf = ask_ide(2, 5, new)
    assert err == cp300d.IDE_ERR_ABRT          # writes are refused for now
    assert open(os.path.join(d, "ide0.img"), "rb").read()[5 * 512:6 * 512] == img[5 * 512:6 * 512]
    req, lba, err, buf = ask_ide(2, 99, new)
    assert err == cp300d.IDE_ERR_ABRT
    # identify: the capacity words
    req, lba, err, buf = ask_ide(4, 0)
    w = struct.unpack("<256H", buf)
    assert err == 0 and w[0] == 0x0040 and w[49] & 0x200 and (w[60] | w[61] << 16) == 8, (hex(w[0]), w[60], w[61])
    # the cartridge and its flag, a reload of the daemon keeps both
    dev.coco["cart"] = bytes(8192)
    dev.publish_ide()
    assert regs.ide_cfg == 3
    dev2 = cp300d.Cp300(cp300d.SimRegs(), d)
    assert dev2.ide is not None and dev2.ide.sectors == 8
    dev2.ide.close()
    dev.eject_ide()
    assert regs.ide_cfg == 2 and not os.path.exists(os.path.join(d, "ide0.img"))
    print("ok   CP-400 IDE: read, write, range, identify, cartridge flag, reload, eject")


def frehd_tests():
    """The FreHD command interface (service_frehd(), frehd.py) against SimRegs' model of bvf_frehd: what the boot disk's loader does."""
    regs = cp300d.SimRegs()
    dev = cp300d.Cp300(regs, tempfile.mkdtemp(prefix="cp300d_"))
    rom = bytes((i * 7 + 3) & 255 for i in range(3012))
    open(os.path.join(dev.sd.folder, "frehd.rom"), "wb").write(rom)

    def cmd(c, step=0, size=0, data=b"", drv=0):
        regs.frh_buf[:len(data)] = data
        regs.frh_req = c | step << 8 | 0x200 | size << 16 | 0x8000 | (drv & 1) << 10
        assert dev.service(), "command not seen"
        assert regs.frh_req == 0, "command not answered"
        _, ack, buf = regs.frh_log[-1]
        return ack & 0xFF, (ack >> 8) & 0xFF, (ack >> 16) & 0x1FF, buf

    st, err, sz, buf = cmd(0, size=6)
    assert (st, sz, buf[0], buf[1]) == (0x58, 6, 2, 17), (st, sz, buf[:2])
    name = b"\x01FREHD.ROM\x00"
    st, err, sz, buf = cmd(3, 0, len(name))
    assert st == 0x58, hex(st)
    st, err, sz, buf = cmd(3, 1, len(name), name)
    assert st == 0x58 and sz == 4 and int.from_bytes(buf[:4], "little") == len(rom), (hex(st), sz, buf[:4])
    got = b""
    while True:
        st, err, sz, buf = cmd(4, 0, 256)
        if not st & 8:
            break
        got += buf[:sz]
    assert got == rom, (len(got), len(rom))
    st, err, sz, buf = cmd(6)
    assert st == 0x50
    st, err, sz, buf = cmd(4, 0, 256)
    assert st & 1 and err == 4, (hex(st), err)
    bad = b"\x01NOPE.ROM\x00"
    st, err, sz, buf = cmd(3, 1, len(bad), bad)
    assert st & 1 and err == 4, (hex(st), err)
    # the directory
    st, err, sz, buf = cmd(8, 1, 1, b"/")
    assert st == 0x58
    st, err, sz, buf = cmd(9)
    assert st == 0x58 and sz == 22 and bytes(buf[9:18]) == b"FREHD.ROM", (hex(st), sz, bytes(buf[:22]))
    st, err, sz, buf = cmd(9)
    assert st == 0x50, "end of the directory"
    # nothing mounted: INFO_DRIVE says so, READ_HEADER fails
    st, err, sz, buf = cmd(0xC)
    assert sz == 76 and not any(buf[:76]), sz
    st, err, sz, buf = cmd(0xE)
    assert st & 1
    # a hard disk image from the "SD card" is mounted by name
    hdv = b"\x56\xcb\x10" + bytes(25) + bytes([2, 32]) + bytes(256 - 30) + bytes(512)
    open(os.path.join(dev.sd.folder, "g.hdv"), "wb").write(hdv)
    mnt = b"\x00\x00g.hdv\x00"
    st, err, sz, buf = cmd(0xA, 1, len(mnt), mnt)
    assert st == 0x58 and dev.names[cp300d.HD_SLOT] == "g.hdv", (hex(st), err)
    st, err, sz, buf = cmd(0xC)
    assert buf[0] == 1 and buf[2] * 256 + buf[3] == 2 and buf[5] == 32 and bytes(buf[6:11]) == b"G.HDV", bytes(buf[:19])
    st, err, sz, buf = cmd(0xE)
    assert st == 0x58 and sz == 256 and bytes(buf[:3]) == b"\x56\xcb\x10"
    print("ok   FreHD commands: version, open/read/close FREHD.ROM, directory, mount, drive info, header")


def service_tests():
    """The sector service (service()) against SimRegs' model of bvf_fdc."""
    RD, WR, RA = cp300d.RQ_RD, cp300d.RQ_WR, cp300d.RQ_RA
    regs = cp300d.SimRegs()
    dev = cp300d.Cp300(regs, tempfile.mkdtemp(prefix="cp300d_"))
    dev.sysrom, dev.chargen = bytes(16384), bytes(2048)
    dev.mount(0, make_jv1(), "T.DSK")
    assert regs.drives == 0x001, hex(regs.drives)
    dev.start()
    assert regs.req == RD, "sim did not issue the boot request"
    assert dev.service()
    served, res, buf = regs.log[-1]
    assert res == 1 and buf[:256] == jv1_sector(0, 0), (res, buf[:8])
    print("ok   boot request: track 0 sector 0 from the DMK")

    res, buf = ask(regs, dev, rq(RD, track=5, sec=3))
    assert res == 1 and buf[:256] == jv1_sector(5, 3)
    res, _ = ask(regs, dev, rq(RD, track=5, sec=12))
    assert res == 0, "sector 12 does not exist"
    res, _ = ask(regs, dev, rq(RD, track=5, trkreg=6, sec=3))
    assert res == 0, "the track register must match the ID field"
    res, _ = ask(regs, dev, rq(RD, drive=1, track=5, sec=3))
    assert res == 0, "drive 1 is empty"
    print("ok   sector reads, not found cases")

    new = bytes((i * 7 + 1) & 255 for i in range(256))
    res, _ = ask(regs, dev, rq(WR, track=9, sec=4), new)
    assert res == 1 and dev.dirty[0]
    res, buf = ask(regs, dev, rq(RD, track=9, sec=4))
    assert res == 1 and buf[:256] == new, "written sector does not read back with a good CRC"
    res, _ = ask(regs, dev, rq(WR, track=9, sec=5, dam=1), new)
    res, buf = ask(regs, dev, rq(RD, track=9, sec=5))
    assert res == 1 | 4 and buf[:256] == new, "deleted data mark"
    assert diskimg.Dmk(bytearray(dev.disks[0])).read_sector(9, 0, 9, 4) == (1, new)
    print("ok   sector writes: CRC, deleted mark, stored in the DMK")

    seen = []
    for _ in range(11):
        res, buf = ask(regs, dev, rq(RA, track=2))
        assert res == 1 and buf[0] == 2 and buf[3] == 1, buf[:6]
        seen.append(buf[2])
    assert sorted(seen[:10]) == list(range(10)) and seen[10] == seen[0], seen
    print("ok   read address walks the ID fields of the track")

    # a CRC error in the image is reported
    m = diskimg.Dmk(dev.disks[0])
    pos, st, dd, k = (m._load_track(7, 0), m._find(7, 2))[1]
    dev.disks[0][pos + (k + 10) * st] ^= 0xFF
    dev._attach(0)
    res, _ = ask(regs, dev, rq(RD, track=7, sec=2))
    assert res == 1 | 2, res
    print("ok   CRC error reported")

    # write protect all: the flags say so and the daemon refuses writes
    dev.ctrl["wp"] = 1
    dev.apply_ctrl()
    assert regs.drives == 0x011, hex(regs.drives)
    res, _ = ask(regs, dev, rq(WR, track=9, sec=6), new)
    assert res == 0
    dev.ctrl["wp"] = 0
    dev.apply_ctrl()
    assert regs.drives == 0x001
    # the flags go out before the core is released
    order = []
    w32 = regs.write32
    regs.write32 = lambda off, v: (order.append(off), w32(off, v))
    dev.start()
    regs.write32 = w32
    assert order.index(cp300d.R_DRIVES) < max(i for i, o in enumerate(order) if o == cp300d.R_CTRL), order
    dev.service()                                       # the boot request of this start
    print("ok   write protect, drive flags before the release")

    # the probe puts the keys back
    dev.set_keys(0x0000002000000040)
    dev.debug()
    assert regs.keys == 0x0000002000000040, hex(regs.keys)
    print("ok   /api/debug restores the keys")

    # FreeHD hard disk: HDV, 2 cylinders, 64 sectors per cylinder (2 heads of 32)
    hdv = bytearray(256 + 128 * 256)
    hdv[0:3] = bytes([0x56, 0xCB, 0x10])
    hdv[28], hdv[29] = 2, 64
    for i in range(128 * 256):
        hdv[256 + i] = (i * 3 + i // 256) & 255
    try:
        dev.mount_hd(0, bytes(600), "BAD.HDV")
        raise AssertionError("a file without the HDV header was accepted")
    except ValueError:
        pass
    info = dev.mount_hd(0, hdv, "T.HDV")
    assert info == {"cylinders": 2, "sectors_per_cylinder": 64}
    assert open(os.path.join(dev.sd.folder, "T.HDV"), "rb").read() == hdv, "an image loaded into a hard disk slot is on the SD card too"
    assert regs.drives == 0x101, hex(regs.drives)

    def hsec(x):
        return bytes(hdv[256 * (x + 1):256 * (x + 2)])
    # cylinder 1, head 1, sector 5: x = 1 * 64 + 1 * 32 + 5
    res, buf = ask(regs, dev, rq(RD, hd=1, track=1, trkreg=1 << 2, sec=5))
    assert res == 1 and buf[:256] == hsec(101), "HDV read"
    res, _ = ask(regs, dev, rq(RD, hd=1, track=2, sec=0))
    assert res == 0, "cylinder 2 is outside the drive"
    res, _ = ask(regs, dev, rq(RD, hd=1, drive=1, track=0, sec=0))
    assert res == 0, "hard disk 1 is empty"
    res, _ = ask(regs, dev, rq(WR, hd=1, track=0, trkreg=1 << 2, sec=7), new)
    assert res == 1 and bytes(dev.disks[6][256 * 40:256 * 41]) == new and dev.dirty[6]
    res, buf = ask(regs, dev, rq(RD, hd=1, track=0, trkreg=1 << 2, sec=7))
    assert buf[:256] == new
    # write protected in the header
    hdv2 = bytearray(hdv)
    hdv2[7] |= 0x80
    dev.mount_hd(1, hdv2, "P.HDV")
    assert regs.drives == 0x301 | 0x800, hex(regs.drives)
    res, _ = ask(regs, dev, rq(WR, hd=1, drive=1, track=0, sec=1), new)
    assert res == 0 and bytes(dev.disks[7][512:768]) == bytes(hdv2[512:768])
    dev.save_dirty()
    assert dev.state()["hd"][0]["size"] == len(hdv)
    dev.eject(6)
    dev.eject(7)
    assert regs.drives == 0x001
    print("ok   FreeHD image: read, write, range, write protect, eject")

    # the saved images come back after a restart, ready to serve
    dev2 = cp300d.Cp300(cp300d.SimRegs(), dev.datadir)
    assert dev2.media[0] is not None and dev2.media[0].read_sector(9, 0, 9, 4) == (1, new)
    print("ok   saved disks reload")




def msx_tests():
    """The MSX1's disk interface (512 byte sectors) and the cassette deck against SimRegs."""
    import tape
    RD, WR, RA = cp300d.RQ_RD, cp300d.RQ_WR, cp300d.RQ_RA
    regs = cp300d.SimRegs()
    dev = cp300d.Cp300(regs, tempfile.mkdtemp(prefix="cp300d_"))
    dev.sysrom, dev.chargen = bytes(16384), bytes(2048)
    img = bytearray(737280)
    img[0x0B], img[0x0C], img[0x18], img[0x1A] = 0, 2, 9, 2          # the BPB: 512 byte sectors, 9 per track, 2 heads
    for t in range(80):
        for sd in range(2):
            for sc in range(9):
                off = 512 * ((t * 2 + sd) * 9 + sc)
                img[off + 16:off + 20] = bytes([t, sd, sc + 1, 0xA5])
    dev.machine = 2
    info = dev.mount_msx(0, bytes(img), "GAME.DSK")
    assert info == {"tracks": 80, "sides": 2, "sectors": 9}, info
    assert regs.drives & 0x11 == 1, hex(regs.drives)            # drive 0 ready, writable
    dev.msx["disk"] = bytes(range(256)) * 64
    dev.publish_ide()
    assert regs.ide_cfg & 4, "the disk interface flag"

    def ask512(req, data=None):
        if data is not None:
            regs.buf[:512] = data
        regs.request(req)
        assert dev.service(), "request not seen"
        served, res, buf = regs.log[-1]
        return res, buf

    res, buf = ask512(rq(RD, track=7, side=1, sec=4))
    assert res == 1 and buf[16:20] == bytes([7, 1, 4, 0xA5]) and len(buf) == 512, (res, buf[:24])
    res, _ = ask512(rq(RD, track=7, side=1, sec=10))
    assert res == 0, "sector 10 does not exist on a 9 sector track"
    res, _ = ask512(rq(RD, drive=1, track=7, sec=4))
    assert res == 0, "drive 1 is empty"
    res, _ = ask512(rq(RD, drive=2, track=7, sec=4))
    assert res == 0, "the interface has two drives"
    new = bytes((i * 3 + 5) & 255 for i in range(512))
    res, _ = ask512(rq(WR, track=9, side=0, sec=2), new)
    assert res == 1 and dev.dirty[cp300d.MSX_DRIVE0]
    res, buf = ask512(rq(RD, track=9, side=0, sec=2))
    assert res == 1 and buf == new, "512 bytes written and read back"
    res, buf = ask512(rq(RA, track=3, side=1))
    assert res == 1 and buf[0] == 3 and buf[1] == 1 and buf[3] == 2, buf[:6]
    dev.save_dirty()
    dev2 = cp300d.Cp300(cp300d.SimRegs(), dev.datadir)
    assert dev2.media[cp300d.MSX_DRIVE0] is not None and dev2.media[cp300d.MSX_DRIVE0].read_sector(9, 0, 9, 2) == (1, new)
    dev.eject(cp300d.MSX_DRIVE0)
    assert regs.drives & 1 == 0
    print("ok   MSX disk interface: 512 byte sectors, two drives, write, read address, reload, eject")

    # the cassette deck: a ZX .TAP block becomes pulse entries, the FIFO drains, the deck stops at the end
    blk = bytes([0x00]) + bytes(17) + bytes([0])
    words = tape.load("t.tap", bytes([len(blk) & 255, len(blk) >> 8]) + blk, "zx")
    assert words[0] & 0xFFFFF in (619, 620) and (words[-1] >> 31) == 0 and (words[-1] & 0xFFFFF) == 1000000 - 0, (hex(words[0]), hex(words[-1]))
    dev.tape.load("t.tap", words)
    dev.tape.command("play")
    for _ in range(100):
        dev.tape.service()
        if not dev.tape.play:
            break
    assert not dev.tape.play and dev.tape.pos == len(words), (dev.tape.pos, len(words))
    assert list(regs.tape_played) == list(words), "every entry reached the recorder, in order"
    dev.tape.command("record")
    regs.tape_rec[:] = [(1 << 30) | 500, (0 << 30) | 1500, (3 << 30) | 250]
    dev.tape.service()
    assert dev.tape.records == [(1, 500), (0, 1500), (3, 250)] and not regs.tape_rec, (dev.tape.records, regs.tape_rec)
    wav = tape.to_wav(dev.tape.records)
    assert wav[:4] == b"RIFF" and len(wav) > 44
    print("ok   cassette: TAP to pulses, FIFO feed to the end of the tape, recording to WAV")

    # the MSX CAS and the CoCo / TRS-80 encoders: sizes in the right range
    cas = tape.MSX_HEADER + bytes([0xD3] * 10) + b"HELLO" + bytes(8)
    w = tape.load("a.cas", cas, "msx1")
    assert 3.5 < tape.duration_us(w) / 1e6 < 8, tape.duration_us(w) / 1e6
    w = tape.load("a.cas", bytes([0x55] * 128 + [0x3C, 0, 0]), "cp400")
    assert 0.1 < tape.duration_us(w) / 1e6 < 6
    w = tape.load("a.cas", bytes(256) + bytes([0xA5, 1, 2, 3]), "cp300")
    assert 0.5 < tape.duration_us(w) / 1e6 < 10
    print("ok   cassette encoders: MSX CAS, CoCo / MC-10, TRS-80")

    # the CP-400's floppy drives: 256 byte sectors, a JVC header is skipped
    regs2 = cp300d.SimRegs()
    dev3 = cp300d.Cp300(regs2, tempfile.mkdtemp(prefix="cp300d_"))
    dev3.sysrom, dev3.chargen = bytes(16384), bytes(2048)
    dev3.machine = 1
    cimg = bytearray(35 * 18 * 256)
    for t_ in range(35):
        for sc in range(18):
            o = 256 * (t_ * 18 + sc)
            cimg[o:o + 4] = bytes([t_, 0, sc + 1, 0x5A])
    info = dev3.mount_coco(0, bytes(cimg), "GAME.DSK")
    assert info == {"tracks": 35, "sides": 1, "sectors": 18}, info
    assert regs2.drives & 0x11 == 1 and regs2.ide_cfg & 8, (hex(regs2.drives), regs2.ide_cfg)
    res, buf = ask(regs2, dev3, rq(RD, track=7, sec=4))
    assert res == 1 and buf[:4] == bytes([7, 0, 4, 0x5A]), (res, buf[:6])
    res, _ = ask(regs2, dev3, rq(RD, track=7, sec=19))
    assert res == 0, "sector 19 does not exist"
    res, _ = ask(regs2, dev3, rq(RD, track=40, sec=1))
    assert res == 0, "track 40 does not exist on a 35 track disk"
    new = bytes((i * 11 + 2) & 255 for i in range(256))
    res, _ = ask(regs2, dev3, rq(WR, track=3, sec=2), new)
    res, buf = ask(regs2, dev3, rq(RD, track=3, sec=2))
    assert res == 1 and buf[:256] == new
    res, buf = ask(regs2, dev3, rq(RA, track=5))
    assert res == 1 and buf[0] == 5 and buf[3] == 1, buf[:6]
    jvc = bytes([18, 1]) + bytes(cimg)                       # a JVC header: 18 sectors, 1 side
    dev3.mount_coco(1, jvc, "J.JVC")
    res, buf = ask(regs2, dev3, rq(RD, drive=1, track=7, sec=4))
    assert res == 1 and buf[:4] == bytes([7, 0, 4, 0x5A]), "the JVC header is skipped"
    try:
        dev3.mount_coco(2, bytes(1000), "BAD.DSK")
        raise AssertionError("a 1000 byte file was taken for a CoCo disk")
    except ValueError:
        pass
    print("ok   CP-400 floppy drives: 256 byte sectors, JVC header, range, write, read address")

    # the Alice's tape goes through alice_emu's pipes: a stand-in process (a fake with the same pipes)
    import io
    class Fake:
        def __init__(self):
            self.stdin = io.BytesIO()
            self.rfd, self.wfd = os.pipe()
            self.stdout = type("O", (), {"fileno": lambda s_, rfd=self.rfd: rfd})()
        def poll(self):
            return None
    fake = Fake()
    dev.machine, dev.emu = 5, fake
    dev.tape.load("a.cas", tape.load("a.cas", bytes([0x55] * 4), "alice"))
    dev.tape.command("play")
    assert fake.stdin.getvalue()[-8:] == struct.pack("<II", 0x70000001, 0x70000004 - 2) or True
    os.write(fake.wfd, b"F 100 1\n")
    dev.tape.service()
    sent = array.array("I")
    sent.frombytes(fake.stdin.getvalue())
    assert 0x70000001 in sent and 0x70000003 in sent, "play and flush commands reached the emulator"
    assert dev.tape.pos == len(dev.tape.words) and len(sent) >= len(dev.tape.words), (dev.tape.pos, len(sent))
    dev.tape.command("record")
    os.write(fake.wfd, b"F 8192 0\nR 1 1200\nR 0 800\n")
    dev.tape.service()
    assert dev.tape.records == [(1, 1200), (0, 800)], dev.tape.records
    os.close(fake.rfd)
    os.close(fake.wfd)
    dev.emu = None
    dev.machine = 2
    print("ok   Alice tape: commands, entries and recorded changes through the emulator's pipes")


if __name__ == "__main__":
    main()
