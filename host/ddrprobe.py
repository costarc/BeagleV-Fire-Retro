#!/usr/bin/env python3
"""Measures the DDR path of the fabric with the probe in the gateware (rtl/bvf_ddr.v), on the board:

    python3 ddrprobe.py [--addr 0xC8000000] [--n 1000]

The fabric master reads and writes the DDR through FIC0 and the MSS. 0xC8000000 is the 32 MB reserved-memory region
"buffer@c8000000" of the stock device tree (the non-cached view of DDR; Linux does not use it). Run it next to the
daemon: it only uses the probe's registers. Run it again with the board busy (for example `yes > /dev/null &` four times,
or a compile) to see the latency under load. All numbers are ACLK cycles and nanoseconds: the ACLK frequency is
measured first (2^20 ACLK cycles against the 42 MHz core clock).
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cp300d  # noqa: E402

R_CTRL, R_ALO, R_AHI, R_WLO, R_WHI, R_CNT = 0x60, 0x64, 0x68, 0x6C, 0x70, 0x74
R_RLO, R_RHI, R_MIN, R_MAX, R_SUM, R_TOTAL, R_RES, R_T42 = 0x78, 0x7C, 0x80, 0x84, 0x88, 0x8C, 0x90, 0x94
CORE_HZ = 42e6


def run(r, mode, addr=0, count=1, wdata=0):
    r.write32(R_ALO, addr & 0xFFFFFFFF)
    r.write32(R_AHI, addr >> 32)
    r.write32(R_WLO, wdata & 0xFFFFFFFF)
    r.write32(R_WHI, wdata >> 32)
    r.write32(R_CNT, count)
    r.write32(R_CTRL, 8 | mode)
    t = time.monotonic()
    while True:
        res = r.read32(R_RES)
        if res & 1 and not res & 2:
            break
        if time.monotonic() - t > 5:
            r.write32(R_CTRL, 0x10)               # abort: the AXI side is held in reset
            time.sleep(0.01)
            r.write32(R_CTRL, 0)
            raise SystemExit("the probe got no answer (mode %d, address %#x): the MSS did not respond on FIC0 (is FIC0's "
                             "fabric-to-processor port enabled in the MSS?) or the address is not DDR. Aborted." % (mode, addr))
    return {"data": r.read32(R_RLO) | r.read32(R_RHI) << 32, "min": r.read32(R_MIN), "max": r.read32(R_MAX),
            "sum": r.read32(R_SUM), "total": r.read32(R_TOTAL), "errors": res >> 4, "resp": (res >> 2) & 3,
            "t42": r.read32(R_T42)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", type=lambda x: int(x, 0), default=0xC8000000)
    ap.add_argument("--n", type=int, default=1000)
    ap.add_argument("--uio", default="/dev/uio0")
    a = ap.parse_args()
    r = cp300d.MemRegs(a.uio)
    if r.read32(0) != cp300d.ID_VALUE:
        raise SystemExit("the gateware's ID is %08X, not %08X" % (r.read32(0), cp300d.ID_VALUE))

    m = run(r, 7)
    aclk = (1 << 20) / (m["t42"] / CORE_HZ)
    ns = 1e9 / aclk
    print("ACLK: %.1f MHz (%.2f ns per cycle; measured as 2^20 cycles in %d core clocks)" % (aclk / 1e6, ns, m["t42"]))

    def line(name, m, n=1):
        print("%-34s min %4d  avg %7.1f  max %5d cycles   = %6.0f / %6.0f / %6.0f ns" % (
            name, m["min"], m["sum"] / n, m["max"], m["min"] * ns, m["sum"] / n * ns, m["max"] * ns))

    m = run(r, 1, a.addr)
    print("resp %d, first word at %#x: %016X" % (m["resp"], a.addr, m["data"]))
    line("one read", m)
    m = run(r, 2, a.addr, wdata=0x0123456789ABCDEF)
    line("one write (to the response)", m)
    m = run(r, 1, a.addr)
    print("read back: %016X %s" % (m["data"], "ok" if m["data"] == 0x0123456789ABCDEF else "DIFFERENT"))
    line("%d reads, one at a time" % a.n, run(r, 3, a.addr, a.n), a.n)
    line("%d writes, one at a time" % a.n, run(r, 4, a.addr, a.n, 0x1000), a.n)
    nb = max(1, a.n // 16)
    m = run(r, 5, a.addr, nb)
    beats = nb * 16
    print("%d bursts of 16 words: %d cycles total = %.1f cycles per burst, %.2f cycles per word, %.0f MB/s" % (
        nb, m["total"], m["total"] / nb, m["total"] / beats, beats * 8 / (m["total"] * ns * 1e-9) / 1e6))
    m = run(r, 6, a.addr, min(a.n, 4096))
    print("write + read back + compare %d words: %d errors, resp %d" % (min(a.n, 4096), m["errors"], m["resp"]))


if __name__ == "__main__":
    main()
