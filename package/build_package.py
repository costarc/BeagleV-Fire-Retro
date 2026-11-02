#!/usr/bin/env python3
"""Builds the distributable CP-300 package for the BeagleV-Fire.

    python build_package.py --gateware <dir with LinuxProgramming/> [--out dist] [--version 0.1.0]

The gateware (mpfs_bitstream.spi, mpfs_dtbo.spi) is built outside this repository (see ../gateware/make_cape.py and
the build notes in ../HANDOVER.md). The package holds: install.sh, the helper cp300-load-gateware, the daemon and page
(syn/beaglev-fire/host), tools/dsk2dmk.py, deploy/ (service, web server snippet, Cockpit entry), the gateware, README.txt,
LICENSE, VERSION, GATEWARE_ID and SOURCE.txt. Output: <out>/cp300-beaglev-fire-<version>.tar.gz and a .sha256 file.
"""
import argparse
import datetime
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BVF = os.path.abspath(os.path.join(HERE, ".."))
REPO = BVF

EXEC = {"install.sh", "cp300-load-gateware"}


def git(*args):
    try:
        return subprocess.check_output(("git",) + args, cwd=REPO, stderr=subprocess.DEVNULL).decode().strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def gateware_id(dtbo):
    """The identifier the overlay puts in /chosen/overlays/CP300-GATEWARE (what the board reports once loaded)."""
    data = open(dtbo, "rb").read()
    found = sorted(set(re.findall(rb"([0-9][\x20-\x7e]*-CP300)\x00", data)))     # every overlay part carries the same string
    if len(found) != 1:
        sys.exit("cannot find the CP300 gateware identifier in %s (found %r)" % (dtbo, found))
    return found[0].decode()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gateware", required=True, help="folder that holds LinuxProgramming/mpfs_bitstream.spi and mpfs_dtbo.spi")
    ap.add_argument("--out", default="dist")
    ap.add_argument("--version", default="0.1.0")
    a = ap.parse_args()

    lp = os.path.join(a.gateware, "LinuxProgramming")
    for f in ("mpfs_bitstream.spi", "mpfs_dtbo.spi"):
        if not os.path.isfile(os.path.join(lp, f)):
            sys.exit("%s not found" % os.path.join(lp, f))
    gw_id = gateware_id(os.path.join(lp, "mpfs_dtbo.spi"))
    name = "cp300-beaglev-fire-%s" % a.version

    stage = tempfile.mkdtemp(prefix="cp300pkg_")
    root = os.path.join(stage, name)
    os.makedirs(root)
    try:
        # software
        host = os.path.join(root, "syn", "beaglev-fire", "host")
        os.makedirs(os.path.dirname(host))
        shutil.copytree(os.path.join(BVF, "host"), host,
                        ignore=shutil.ignore_patterns("__pycache__", "data", "regs32.so", "test_cp300d.py", "deploy", ".gitignore"))
        # the Alice's 6803 emulator (compiled on the board by install.sh); no ROM, no tests, no build folder
        shutil.copytree(os.path.join(BVF, "alice", "emu"), os.path.join(root, "syn", "beaglev-fire", "alice", "emu"),
                        ignore=shutil.ignore_patterns("build", "test_mc6803.c", "run_tests.sh", ".gitignore"))
        os.makedirs(os.path.join(root, "tools"))
        shutil.copy(os.path.join(REPO, "tools", "dsk2dmk.py"), os.path.join(root, "tools"))
        shutil.copytree(os.path.join(BVF, "host", "deploy"), os.path.join(root, "deploy"),
                        ignore=shutil.ignore_patterns("install.sh"))
        # gateware
        shutil.copytree(lp, os.path.join(root, "gateware", "LinuxProgramming"))
        # installer and docs
        for f in ("install.sh", "cp300-load-gateware", "README.txt", "DISCLAIMER.txt", "MSX1-LICENSE.txt"):
            shutil.copy(os.path.join(HERE, f), root)
        shutil.copy(os.path.join(REPO, "LICENSE"), root)
        open(os.path.join(root, "VERSION"), "w", newline="\n").write(a.version + "\n")
        open(os.path.join(root, "GATEWARE_ID"), "w", newline="\n").write(gw_id + "\n")
        with open(os.path.join(root, "SOURCE.txt"), "w", newline="\n") as f:
            f.write("CP-300 for the BeagleV-Fire %s, built %s\n" % (a.version, datetime.date.today().isoformat()))
            f.write("Source (GPL v3): %s\n" % (git("remote", "get-url", "origin") or "the CP-300_FPGA repository"))
            f.write("Commit: %s\n" % (git("describe", "--always", "--dirty") or "unknown"))
            f.write("Gateware: %s, built from the BeagleV-Fire gateware framework (git.beagleboard.org/beaglev-fire/gateware)\n"
                    "with the CP-300 cape in syn/beaglev-fire/gateware (make_cape.py) and the HSS pinned by that framework.\n" % gw_id)
            f.write("SHA-256 of the gateware files:\n")
            for n in sorted(os.listdir(os.path.join(root, "gateware", "LinuxProgramming"))):
                h = hashlib.sha256(open(os.path.join(root, "gateware", "LinuxProgramming", n), "rb").read()).hexdigest()
                f.write("  %s  %s\n" % (h, n))
        # normalise line endings of the text files that run on the board
        for dp, _, fs in os.walk(root):
            for n in fs:
                if n.endswith((".sh", ".py", ".c", ".service", ".conf", ".json", ".html", ".txt")) or n in EXEC:
                    p = os.path.join(dp, n)
                    b = open(p, "rb").read()
                    if b"\r\n" in b:
                        open(p, "wb").write(b.replace(b"\r\n", b"\n"))

        # reproducible tarball: sorted, fixed owner and times, executable bits where needed
        os.makedirs(a.out, exist_ok=True)
        out = os.path.join(a.out, name + ".tar.gz")
        mtime = 1700000000

        def norm(ti):
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = mtime
            ti.mode = 0o755 if (ti.isdir() or os.path.basename(ti.name) in EXEC) else 0o644
            return ti

        with open(out, "wb") as raw:
            import gzip
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=mtime, filename="") as gz:
                with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
                    names = []
                    for dp, dn, fs in os.walk(root):
                        for n in dn + fs:
                            names.append(os.path.join(dp, n))
                    for p in sorted(names):
                        tf.add(p, arcname=os.path.relpath(p, stage).replace(os.sep, "/"), recursive=False, filter=norm)
        sha = hashlib.sha256(open(out, "rb").read()).hexdigest()
        open(out + ".sha256", "w", newline="\n").write("%s  %s\n" % (sha, os.path.basename(out)))
        print("package:", out, os.path.getsize(out), "bytes")
        print("gateware id:", gw_id)
        print("sha256:", sha)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


if __name__ == "__main__":
    main()
