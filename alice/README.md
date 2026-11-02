# Matra & Hachette Alice on the BeagleV-Fire

Machine 5 of the multi-machine bitstream. The Alice is a French clone of the Tandy MC-10 (1983). Its CPU, a Motorola
MC6803, is **emulated in C on Linux**; the FPGA keeps what has hard real time or is already there: the MC6847 video and
the picture path of the CP-400 (and the MC-1000), the video RAM, the 1-bit sound path. No 6803 HDL core.

Status (2026-11-01): step 1 is done (emulator + tests, `emu/`), step 2 (the FPGA side, host runner, daemon, web page) is done and
simulated (section 3); a gateware build and the board test are open (section 4).

## 1. The machine (what the emulator models, and how sure that is)

Everything below comes from MAME's `mc10.cpp` / `m6801.cpp` (read through a web fetch, 2026-11-01), not from a schematic and
not from a ROM disassembly. **Re-check each item against the ROM once the user supplies it** (never commit a ROM).

| | |
|---|---|
| CPU | MC6803, 3.579545 MHz / 4 = 894 886 Hz, no on-chip ROM, mode pins not used by the machine |
| Memory | on-chip registers `$00-$1F`, on-chip RAM `$80-$FF`; RAM `$4000-$4FFF` (4 KB; 8, 20 or 32 KB with expansion; the `$BF00` page is I/O); 8 KB ROM `$E000-$FFFF`, reset vector `$FFFE` |
| `$BFFF` write | b7 DAC (1-bit sound), b6 CSS, b5 A/G, b4 GM0, b3 GM1, b2 GM2 and INT/EXT; b1:0 unused |
| `$BFFF` read | keyboard rows (active low) of the columns selected on P1 |
| P1 (out) | keyboard column strobe PB0..PB7, active low |
| P2 | b0 out: cassette out / RS-232 TX; b1 in: keyboard row 6 (CONTROL on PB0, BREAK on PB2, SHIFT on PB7); b2 in: RS-232 RX; b3 in: CTS; b4 in: cassette in |
| Video | MC6847 reading the RAM from `$4000`; per byte b6 = INV, b7 = A/S (so the 6847's attributes are in the VRAM data, like the CP-400 core's `an_s <= vdg_data(7)`, `inv <= vdg_data(6)`) |
| Keyboard | 8 columns x 7 rows, matrix in `emu/alice.c` (MC-10 layout and the AZERTY differences of the Alice, 7 keys) |

The original **Alice** has the MC-10 map (8 KB ROM at `$E000`). The Alice 32 / 90 (EF9345 video, ROM 16 KB at `$C000`, RAM at
`$3000`) are different machines; the harness can run their ROM (section 2), but the FPGA design below is for the MC6847 Alice.

Open points to settle from the ROM: whether the 6847's field sync reaches the CPU (IRQ or a readable bit; if it does, the
FPGA must provide it and the emulator must see it), what the ROM does with the on-chip timer, SCI and P3/P4, the exact
meaning of `$BFFF` bits 6:7 on reads, and cassette timing (the emulator only counts P2.0 edges).

## 2. Step 1: the emulator (`emu/`)

| File | |
|---|---|
| `mc6803.h`, `mc6803.c` | the CPU: 6800 set + 6801/6803 additions (LDD/STD/ADDD/SUBD, ASLD/LSRD, MUL, ABX, PSHX/PULX), on-chip ports P1-P4, DDRs, on-chip RAM, free running counter, output compare, input capture, interrupts (NMI, IRQ1, ICI, OCI, TOI, SWI, WAI). Cycle counts per opcode as in the 6801 data sheet, checked against MAME's table. **No malloc, no libc, no globals**: a bus callback interface (`rd`, `wr`, `port_in`, `port_out`), so the same file runs bare-metal. |
| `test_mc6803.c` | 93 checks, expected values worked out by hand (flags of every ALU group, 16-bit ops, MUL, DAA, stack and interrupt frames, JSR/RTS cycles, timer flags and their clear sequences, ports, on-chip RAM never reaching the bus), and a sweep of all 256 opcodes against an independently written legal-opcode and length table |
| `alice.c` | the machine around it (RAM, ROM, `$BFFF`, keyboard matrix, DAC and cassette edge counters, VRAM as a plain array, a text-screen dump, key typing), a self test with a hand-assembled ROM, a benchmark |
| `run_tests.sh` | builds with the mingw64 gcc and runs both tests |

`sh run_tests.sh` -> `93 checks, 0 failures` and `alice selftest: ok`.

Limits of the core (documented in `mc6803.h`): peripherals advance at the end of each instruction (error below one
instruction, at most 12 cycles = 13 us), no dummy bus cycles, serial interface and port 3 handshake not modelled, illegal
opcodes count as 4-cycle no-ops and are recorded in `illegal`/`illegal_pc`. The behaviour of CPX (C unchanged), the TCSR
read-then-access flag clearing and the FRC write preset `$FFF8` follow the 6801 data sheet / MAME.

**ROM run.** The user supplied ROMs in `C:\Users\roniv\Desktop\Retro\Alice32` (never committed). They are the **Alice 32**
(`alice32.rom`, 16 KB, SHA-1 `f34e61c3...` = MAME's dump, and `charset.rom`, 8 KB, for the **EF9345**), not the original
MC6847 Alice, so the MC6847 BASIC prompt could not be checked. The harness runs the Alice 32 ROM anyway (16 KB at `$C000`,
RAM at `$3000`, EF9345 registers at `$BF20-$BF29` as a stub that is never busy and logs its writes, `-eflog file`):

- reset vector `$F72E`; **0 illegal opcodes** in 5 s of machine time;
- the ROM initialises the EF9345 (indirect register writes), runs a RAM test, initialises it again at 0.28 s and then sits in
  its wait-for-key loop (pc `$F861-$F862`, a delay inside the keyboard poll `BSR $F83F / BSR $F883`);
- typing `PRINT 1+1` through the keyboard matrix makes it write 168 more EF9345 register values (echo and execution), so the
  keyboard scan (P1 strobe, `$BFFF` read, P2.1) works with the ROM.

That is good evidence that the core is right (a 16 KB ROM exercises most addressing modes), but **the screen could not be
looked at**: text goes through the EF9345, which is not modelled. The original 8 KB Alice ROM (MAME SHA-1 `c2166b91...`) is
still needed for the MC6847 path.

**MC-10 ROM run (`Desktop\Retro\Alice\MC10.BIN`, 8 KB, SHA-1 `4afff2b4...` = MAME's `mc10.rom`):** the ROM reaches the
BASIC prompt. After 3 s of machine time the VRAM array shows `MICROCOLOR BASIC 1.0 / COPYRIGHT 1982 MICROSOFT / OK` and the
cursor, and 0 illegal opcodes. Typing `PRINT 1+1` + Enter through the keyboard matrix prints ` 2` and a new `OK`. So the core,
the memory map, the `$BFFF` keyboard read and the P1/P2 scan are verified against a real ROM for the MC-10; the Alice ROM
(same hardware) is expected to behave the same. (The `#` in the dump is the cursor, a character with the INV bit set.)

**Decision (settled by the user, 2026-11-01): the target is the original Alice / MC-10 with the MC6847, as in the original
plan. The Alice 32 / EF9345 is out of scope** (no EF9345 emulation, no software-rendered frame path). The harness still runs
the 16 KB Alice 32 ROM as a CPU test only. To run a ROM:

```
sh run_tests.sh                       # builds emu/build/alice
emu/build/alice alice.rom -secs 3 -alice -type "PRINT 1+1\n"
```

It prints the 32 x 16 text screen from the VRAM array, the last mode written to `$BFFF`, illegal opcode count and pc. The
first thing to check is that `OK` (the MC-10 banner, see the ROM) appears on screen. Illegal opcodes or a ROM stuck in a
loop on an unmodelled I/O bit are the likely first problems.

Speed on the PC (`alice --bench`, mingw gcc -O2, spinning `BRA *` ROM = best case, 3 cycles per instruction): about 165 M
instructions/s, i.e. 500x real time. A real program mix will be slower; the machine needs about 0.2-0.3 M instructions/s. A
U54 hart at 600 MHz (in-order) will probably do 5-10 M instructions/s (estimate, not measured), which is 2-5 % of one hart.

## 3. Step 2: the FPGA side (done, simulated; not built or run on the board)

Status (2026-11-01): **machine 5 is implemented in `rtl/bvf_mc1000.v` (port `alice`), `rtl/bvf_core_bus.v`, `rtl/bvf_regs.v`, the
host runner `emu/alice_emu.c`, the daemon (`host/cp300d.py`), the web page and the package scripts.** The design differs from the
first draft of this note (the host as bus master of the CP-400's SAM): it reuses the **MC-1000's VDG** instead, which generates
its own video addresses, so no part of `cp400_core` changes and no SAM timing is involved.

### 3.1 What crosses the FPGA boundary

| Direction | What | How |
|---|---|---|
| emulator -> FPGA | the video RAM (the Alice's `$4000-$57FF`, 6 KB, offset 0..6143) | window `0x60000`: word n = bytes 4n..4n+3 (first byte in bits 7:0); the gateware writes the four bytes into the pool's VRAM port, one per clock (`al_busy` = register `0xA0` b8) |
| emulator -> FPGA | the `$BFFF` latch (b7 DAC, b6 CSS, b5 A/G, b4 GM0, b3 GM1, b2 GM2 and INT/EXT) | register `0xA0` b7:0, written right after the instruction that stored it |
| FPGA -> emulator | the key matrix | the existing `KEYS_LO/HI` registers, bit = 8 * column + row, read every slice |

The 6803's own RAM and ROM stay in the emulator's memory: nothing crosses the FIC per 6803 cycle. The emulator keeps a shadow of the
video RAM and, after each ~1 ms slice, writes the words that changed (a full 6 KB redraw is 1536 posted writes).

### 3.2 The video

`bvf_mc1000` with `alice = 1`: the Z80 is held (machine select 5 is not its `mm`), the VDG gets its mode from `al_mode`
(`an_g_i = b5`, `gm_i = {b2, b3, b4}`, `css_i = b6`, `intn_ext_i = b2`) and the per-byte attributes from the video data
(`an_s_i = data b7`, `inv_i = data b6`: the Alice's format, which differs from the MC-1000's, where INV is b7). The character
ROM is the 6847's (code = data b5:0, INV inverts), semigraphics 4 reads colour from b6:4 and the pixels from b3:0. The audio is
`{al_mode b7, 8'h00}` into the shared audio FIFO (edges are timestamped by the gateware at the register write).
The pool's VRAM (the CP-400's ROM blocks, as for the MSX1 and the MC-1000) and the frame path (`bvf_fb`, 256 x 192 colour index) are
shared; the picture comes out exactly as the MC-1000's (`VPAL` in the web page). Cost: about 60 LUT (word sequencer, register,
muxes), no block RAM; no second VDG.

### 3.3 Verified in simulation (ModelSim, `sim/run_z80sys.sh`, `MACH=5`)

`ALICEVRAM=<file> MACH=5 sh run_z80sys.sh 60` writes the window and the register from a VRAM + mode image and captures the frame
(`bvf_core_bus` + pool + VDG + frame RAM, as in the gateware):
- the MC-10 ROM's screen after 3 s of machine time (image from `emu/alice MC10.BIN -secs 3 -dump file`): the banner
  `MICROCOLOR BASIC 1.0 / COPYRIGHT 1982 MICROSOFT / OK`, dark on bright green (`sim/alice_mc10_prompt.png`). Its cursor, `$8F`
  (semigraphics colour 0, all four quadrants), is green on green: invisible, as the VDG's colour table gives it;
- semigraphics 4, per byte: eight colour blocks and half blocks (`sim/alice_semi.png`);
- RG6 (256 x 192 graphics, mode `$3C`): frame, stripes and a diagonal (`sim/alice_rg6.png`).
`emu/alice_emu --sim file` (the real-time runner against a register array on the PC) produces a VRAM + mode image byte-identical to the
harness' after 3 s of machine time. The Python daemon tests (`host/test_cp300d.py`) cover the ROM endpoint and the machine switch.

### 3.4 Registers and windows (`rtl/bvf_regs.v`; ID `0x43503004`)

| Where | What |
|---|---|
| CTRL b9:8,5:4 = **5** | machine select (the 4-bit select of the z80 line) |
| `0x60000` window (write only) | word n = VRAM bytes 4n..4n+3, n = 0..1535 |
| `0xA0` ALICE | b7:0 the `$BFFF` value; read: b8 = window busy (4 clocks per word; the host's writes are slower anyway) |
| `KEYS_LO/HI` (0x0C / 0x10) | column n = bits 8n+6:8n (rows 0..6), pressed = 1 |

## 4. Software and what is left

- `emu/alice_emu.c` (+ `alice.c`, `mc6803.c`): maps the register window (`--uio /dev/uioN` or `--mem 0xADDR`, 32 bit accesses), runs the 6803
  paced against `CLOCK_MONOTONIC` in slices of about 1 ms (instruction-accurate `$BFFF` writes), `SIGUSR1` = reset, `SIGTERM` = stop;
  `--sim file` runs it against an array. **The hardware mapping is not compiled or run on the PC (Windows has no `sys/mman.h`): first
  build it on the board.** `install.sh` compiles it into `alice/emu/build/alice_emu`; the daemon (`Cp300._start_emu`) starts it at power on,
  stops it at power off or a machine change, and sends `SIGUSR1` on RESET. `PUT /api/rom/alice` takes the 8 KB ROM; web page: machine
  "Alice (MC-10)", AZERTY key map and on-screen keyboard (the matrix of `alice.c`).
- Not done / not known: **a gateware build** (resources are an estimate: the 4316 trial was 85 % LUT, 76 of 84 block RAMs; Alice adds no
  block RAM); running on the board (FIC write latency decides the sound edge jitter: one register write, a few us, plus the
  scheduling of the process: pinning it to a core with `taskset` / `SCHED_FIFO` is not done); the original Alice ROM (only the MC-10 ROM
  was run); cassette (the emulator counts P2.0 edges, nothing is played or recorded); the field sync to the CPU (the MC-10 ROM ran to its
  prompt without it; whether the Alice needs the 6847's FS on the CPU's IRQ is open); the INT/EXT = b2 sharing in graphics modes was taken
  from MAME and not checked on hardware.

## 5. Software structure for later, and the bare-metal question

The emulator is split so the final review (bare-metal on one U54 hart, AMP, Linux on the others) only swaps the platform
layer:

```
mc6803.c        the CPU, no dependency (done)
alice_machine.c memory map, keyboard, shadow VRAM, DAC (today inside alice.c): uses only
fpga_if.h       vram_flush(words), mode(val), dac(bit), keys(), time()  -- to be written
  - linux:      mmap of the UIO register window (as the daemon), CLOCK_MONOTONIC pacing, pinned process
  - bare-metal: the same calls through the FIC aperture, timer CSR (mtime) pacing, the hart owns its caches
```

Why it should work, from the numbers: the load is 0.2-0.3 M instructions/s (2-5 % of a hart), memory is a few tens of KB, no
call crosses the FIC per 6803 cycle (section 3.1). What the review has to decide is the jitter of the 1-bit sound and of
the batched VRAM flush on Linux (a pinned `SCHED_FIFO` process with `isolcpus`/`nohz_full` is the first step, no boot change)
against the cost of the boot-chain change for AMP (HSS payload, or remoteproc through the IHC if the kernel has it). Not
measured yet: FIC write/read latency and the non-cached DDR/register access times.
