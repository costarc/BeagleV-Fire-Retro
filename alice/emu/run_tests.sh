#!/bin/sh
# Build and run the MC6803 tests and the Alice machine harness self test.
# gcc: C:/apps/msys64/mingw64/bin (the same one used for iverilog)
set -e
cd "$(dirname "$0")"
export PATH="/c/apps/msys64/mingw64/bin:$PATH"
CFLAGS="-O2 -Wall -Wextra -std=c99"
mkdir -p build
gcc $CFLAGS -o build/test_mc6803 test_mc6803.c mc6803.c
./build/test_mc6803
gcc $CFLAGS -o build/alice alice.c mc6803.c
./build/alice --selftest
gcc $CFLAGS -std=gnu99 -Wno-unused-function -o build/alice_emu alice_emu.c mc6803.c
gcc $CFLAGS -Wno-unused-function -o build/test_tape test_tape.c
./build/test_tape
