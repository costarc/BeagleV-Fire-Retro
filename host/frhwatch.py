#!/usr/bin/env python3
"""Board-side check of the FreHD command interface: watches STATUS b1 and FRH_REQ for a few seconds.
Run it, then press Reset in the page (or pass --reset to do it through the daemon). Prints every different REQ seen."""
import argparse
import json
import os
import sys
import threading
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cp300d  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--uio", default="/dev/uio0")
ap.add_argument("--seconds", type=float, default=8)
ap.add_argument("--reset", action="store_true", help="press Reset through the daemon after one second")
a = ap.parse_args()
r = cp300d.MemRegs(a.uio)
if a.reset:
    def kick():
        time.sleep(1)
        req = urllib.request.Request("http://127.0.0.1:8300/api/ctrl", data=json.dumps({"reset": 1}).encode(), method="POST")
        urllib.request.urlopen(req).read()
    threading.Thread(target=kick, daemon=True).start()
seen = {}
t0 = time.monotonic()
n = 0
while time.monotonic() - t0 < a.seconds:
    st = r.read32(cp300d.R_STATUS)
    q = r.read32(cp300d.R_FRH_REQ)
    n += 1
    key = (q & 0x3FF, st & 2)
    if key not in seen:
        seen[key] = time.monotonic() - t0
        print("%.3f s  STATUS %02X  FRH_REQ %08X  (cmd %02X step %d pending %d size %d)" % (
            seen[key], st & 0xFF, q, q & 0xFF, (q >> 8) & 1, (q >> 9) & 1, (q >> 16) & 0x1FF), flush=True)
print("%d reads, %d different states" % (n, len(seen)))
