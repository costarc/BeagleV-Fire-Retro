# Handover: several machines in one BeagleV-Fire bitstream

Written 2026-10-30. Start here for the multi-machine work on the BeagleV-Fire. The current state of the port is in
[HANDOVER.md](HANDOVER.md), the build procedure in [BUILDING.md](BUILDING.md), the design in
[../../docs/beaglev-fire-technical-paper.md](../../docs/beaglev-fire-technical-paper.md).

## Goal

One bitstream with three machines, selected by a register the Linux daemon writes. Switching is instant: no reflash, no
reboot.

| Machine | Notes |
|---|---|
| CP-300 | exists (TRS-80 Model III compatible) |
| TRS-80 Color Computer 2 / CP-400 | 6809, MC6847 video, SAM, two PIAs |
| MSX2 | **MSX2 only**, no separate MSX1 core (MSX2 runs MSX1 software) |

Ruled out: the X68000. It is several times bigger than the whole MPFS025T.

## Chosen cores (decided 2026-10-30)

| Machine | Core | Source | Licence |
|---|---|---|---|
| CP-300 | this repository | `rtl/`, `syn/analogue/src/fpga/core/ht1080z_ext.vhd` | GPLv3 |
| CP-400 / CoCo 2 | the user's own core: Victor Trucco's Multicore core (based on Mark McDougall's PACE); `cpu09`, `mc6847`, `mc6883`, `pia6821` | `C:\Users\roniv\Dev\github\CP400_COLOR_FPGA\FPGA\src` | Trucco files BSD-style; `cpu09` (John Kent) GPLv3 |
| MSX2 | KdL's OneChip MSX (OCM-PLD), MSX2+ with V9958 | KdL's release (not on this machine yet; an older OCM port is in `C:\Users\roniv\Dev\github\OneChipMSX_DE0`) | ESE Artists' Factory licence: BSD-style plus "may not be sold, nor used in a commercial product or activity" |

**All three go in one bitstream** (the user's decision). The ESE no-commercial clause is not compatible with GPLv3
if the combined bitstream counts as one work; the user accepts that and the project stays non-commercial. Keep every
original copyright header, and say in the README and the package that the MSX2 part may not be used commercially.

Measured sizes (Cyclone III logic elements, roughly comparable to 4-input LUTs):

- **CP-400**, whole DE0 build: 4,673 LE, 216 Kbit of block RAM (ROMs). That includes SD/IDE, HDMI, a frame buffer and
  PS/2, which the host replaces. The machine alone is about 3K (estimate). Its 64 KB RAM is external SRAM on the DE0.
- **OneChip MSX** (the older `OneChipMSX_DE0` build): 12,944 LE in total. VDP 2.6K, T80 2.2K, OPLL 1.9K,
  IPL ROM as logic 1.3K, top glue 1.2K, 2x MegaRAM/SCC 0.8K, UART 0.6K, PSG 0.5K. A minimal MSX2 (VDP, PSG, slots,
  mapper, RTC; no OPLL, SCC, UART; IPL ROM in block RAM or loaded by the host) is about 4.5K without its own Z80.

**Memory.** OneChip MSX keeps main RAM, ROMs and VRAM in SDRAM behind a fixed-timing controller. The BeagleV-Fire
fabric has no SDRAM, only DDR through AXI with variable latency. So the VRAM (128 KB) moves into block RAM, and
the main RAM and ROMs go to DDR with Z80 wait states: step 2's latency measurement decides this.

**Shared block RAM pool.** Only one machine runs at a time, so one 128 KB pool can be the CP-300 RAM, the CP-400 RAM
or the MSX VRAM. The two smaller machines may then not need DDR at all.

## Where the area goes today

From `D:\bvf\gw943\work\libero\designer\CP300_943F37F\CP300_943F37F_compile_netlist_hier_resources.csv` (package
0.3.0 build, pre-layout; add up the rows by instance prefix). The MPFS025T has about 23K 4-input LUTs and 84 large block
RAMs (LSRAM, 20 Kbit each).

| Block | 4LUT | LSRAM |
|---|---|---|
| Board base design (PCIe on M.2, processor subsystem wrappers, clocks) | ~2.9K | 2 |
| CP-300 machine (`cp300/core/cp300`: Z80, video, WD1793, keyboard) | ~3.9K | 13 |
| **IO controller** (`cp300/core/io_ctrl`) | **~9.5K** | 4 |
| Host interface: bridge, registers, frame capture, disk mailbox and track RAM, audio, 64 KB Z80 RAM | ~3.0K | 57 |
| **Total** | **~19K** | **76** |

Of the IO controller's ~9.5K, the T80 is ~2.3K. The other ~7.2K is its 16 KB firmware ROM: the `FW_ROM` constant in
`syn/analogue/src/fpga/core/io_ctrl_pocket.vhd` is synthesised as logic, not as block RAM.

On the BeagleV-Fire the IO controller has no menu or OSD job (the browser is the menu, Linux is the storage). It only
serves DMK disk images to the WD1793, which the daemon can do.

## Plan

Do the steps in order. Measure after each one before going on: the estimates below are not builds.

### 1. Remove the IO controller (BeagleV-Fire build only)

Frees about 9.5K LUTs and 12 LSRAM (its 8 KB RAM, 4 blocks, and the 16 KB track RAM, 8 blocks).

- **Gateware** (`rtl/`). In `bvf_core_bus.v`, replace `io_ctrl_pocket` and `bvf_dataslot` with a small glue block that
  puts the WD1793 service interface of `ht1080z_ext` into the register map of `bvf_regs.v`:
  - requests: `fdc_svc_rd/wr/ra`, `fdc_svc_track/trkreg/sector/dam`, `fdc_drive`, `fdc_side`;
  - answer: `fdc_svc_ack`, `fdc_res_found/crc/dam`;
  - the 512-byte sector buffer: `fdc_buff_addr/dout/din/wr`;
  - drive state: `drv_ready`, `drv_wp`.

  A pending request raises the existing `irq` (cape `INT[0]` = `MSS_INT_F2M[8]` = PLIC 126, already verified on the
  board). Drop the track RAM window if nothing uses it any more. Keep the frame capture, audio FIFO, keys and ROM loader.
  If the register map changes incompatibly, change the ID register value (`0x43503001`), and say so.
- **Unchanged:** the CP-300 core (`ht1080z_ext`, `rtl/`). The other ports (DE0, Pocket, MiSTer) keep their IO controller.
- **Daemon** (`host/cp300d.py`). Port the sector logic of `firmware/dmk.c` (465 lines) to Python: read sector, write
  sector, read address, deleted-data marks, CRC status, write protect. Reuse `tools/dsk2dmk.py` where it helps. The
  daemon also takes over the firmware's other jobs: drive ready / write protect, and holding the machine until drive 0 is
  mounted.
- **Tests.** Extend `SimRegs` and `host/test_cp300d.py` so the new path runs without hardware: a JV1 image converted to
  DMK, sector reads and writes, read address. Keep `sim/run.sh` and `sim/run_apb.sh` passing, and add a testbench for the
  new FDC registers.
- **Risk.** A request now goes to Linux once per sector (today once per track). The WD1793 waits for the acknowledge, so
  a slow answer slows the disk but does not corrupt it. Timing-sensitive or copy-protected disks could notice.

### 2. Machine memory in DDR

- **Path.** In the CP-300 build, FIC0's AXI4 target port (fabric to processor, 64 bits) is unused: its inputs are tied to
  constants in the generated top level. FIC1's target carries the M.2/PCIe interface.
- **Reserved memory.** Reserve a physically contiguous DDR region from Linux. The framework's SmartHLS option has an
  example: `udmabuf-overlay.dtso`, 32 MB in the non-cached region `dma_non_cached_low`. Use the non-cached view, or flush
  caches.
- **Latency test.** Build a small AXI master on FIC0 and **measure the latency** under Linux load. Nothing is measured yet.
- **Then** move the CP-300's 64 KB RAM there through the core's existing `ext_ram_wait` input (tied to 0 today), and
  consider the ROMs and the frame buffer (the fabric writing frames to DDR would replace the slow register-bus frame read).

### 3. MSX2 next to the CP-300

- **CPU.** Share the CP-300's Z80.
- **Video RAM.** The V9938's 128 KB stays on-chip because of its timing (about 64 LSRAM). That works only once the
  CP-300 RAM and the frame buffer are in DDR.
- **Shared block RAM.** One machine runs at a time, so block RAM is shared between machines.
- **Clock.** A second output of the existing PLL at 21.477 MHz.
- **Estimate:** ~5–6K LUTs without its own Z80 and without MSX-MUSIC / SCC sound. The V9938 is the biggest unknown.
- **Licences.** Check the licence of any open-source MSX2 or V9938 core before reusing it (the One Chip MSX lineage,
  the MiSTer MSX core).

### 4. CoCo 2 / CP-400

About 4–5K LUTs (estimate).

### Budget for all three (estimate)

About 20–21K of the 23K LUTs, roughly 90%, and about 70 of the 84 LSRAM with sharing and DDR. A design that full may fail
to route or meet timing; only a trial build says. Fallback: two bitstreams (for example CP-300 + CoCo 2, and MSX2),
switched by reflashing.

## Build notes

[BUILDING.md](BUILDING.md) has the full procedure.

- **Framework copy.** `D:\bvf\gw943` already has the two framework edits.
- **Cape.** Run `python syn/beaglev-fire/gateware/make_cape.py D:/bvf/gw943` from your worktree. A new worktree needs
  `git submodule update --init rtl/T80` first.
- **Libero.** Copy the run script `D:\bvf\run_gw943_4302.ps1` and raise `DESIGN_VERSION`: next is **4304** (4302 =
  0.3.0, 4303 = 0.4.0). Also give it a new log file name. A run takes about 10 minutes; start it in the background and
  check every few minutes.
- **Overlay.** Copy `C:\Users\roniv\hssxfer\mkdtbo3.sh` and set the identity to `2025.10-13-g943f37f-4304-CP300`. Run it
  from PowerShell as `wsl bash /mnt/c/Users/roniv/hssxfer/<script>`; it fails from Git Bash.
- **Package.** `package/build_package.py` with the next version after the latest in `releases/`. Build it from a committed
  tree, so `SOURCE.txt` names a clean commit.
- **Board.** `ssh -i ~/.ssh/id_ed25519_bvf -o IdentitiesOnly=yes beagle@beaglev`. There is no sudo over SSH: flashing is
  the user's step (`sudo ./install.sh`, or `sudo cp300-load-gateware`). If the board does not reboot by itself after the
  flash, `sudo reboot` loads the new gateware.
- **Checkout.** Other sessions use the main checkout `C:\Users\roniv\Dev\github\CP-300_FPGA`: work in your own worktree
  and never switch branches there. Commit to your branch; ask the user before merging to master or pushing.

## Progress on step 1 (branch feature/remove-io-ctrl)

- **Gateware done, simulated:** `rtl/bvf_fdc.v` replaces `io_ctrl_pocket`, `bvf_dataslot` and `bvf_trk_ram`.
  Registers REQ / ACK / DRIVES at 0x40 / 0x44 / 0x48, the 512-byte sector buffer at 0x20000, ID `0x43503002`.
  DRIVES keeps its value while CTRL.run = 0, so the daemon sets the flags before releasing the core.
- **The IO controller also served the FreeHD hard disks** (WD1010, `hd_svc`): the daemon serves them too.
- **Daemon done:** `host/diskimg.py` is the Python port of `firmware/dmk.c` and the HDV sector code; `cp300d.py`
  answers one sector per request. Checked against `dmk.c` compiled on the PC (file-backed shim, `DMK_GUESS=0` as
  the Pocket build): identical results and identical images after the writes, on a JV1, a mixed SD/DD two-sided
  image with deleted marks, a bad CRC, a 512-byte sector and a duplicate ID, and the simulation's disk.
- **Daemon-side changes in behaviour:** "write protect all" is applied by the daemon (DRIVES flags, and writes are
  refused); writes to an HDV with the header's protect bit are refused (the firmware did not check it).
- **Libero build 4304 done (2026-10-30):** builds, "Timing constraints have been met". Result below. Docs updated.
- **Still to do:** a test of the package on the board (flashing is the user's step).

### Result of the 4304 build (gateware without the IO controller)

From `CP300_943F37F_compile_netlist_hier_resources.csv` of this build (post-synthesis, rows added up by instance;
"LSRAM interface logic" is counted in the LUT and DFF columns, as in the Libero totals). The MPFS025T has 22,956 4LUT and 84 LSRAM.

| Block | 4LUT | DFF | LSRAM | uSRAM | Before (0.3.0/0.4.0) |
|---|---|---|---|---|---|
| Board base (processor subsystem, M.2/PCIe initiators, clocks) | 2,919 | 2,835 | 2 | 16 | ~2.9K LUT, 2 LSRAM |
| CP-300 machine (`cp300/core/cp300`: Z80, video, WD1793, WD1010, keyboard) | 3,887 | 1,234 | 13 | 0 | ~3.9K, 13 |
| Host interface (`fb` 632, `regs` 290, `fdc` 168, `aud` 113, `bus` 13) | 1,216 | 1,196 | 17 | 8 | |
| 64 KB Z80 RAM and glue primitives (`core/Primitives`) | 1,204 | 1,154 | 32 | 0 | |
| Host interface plus RAM, together | 2,420 | 2,350 | 49 | 8 | ~3.0K, 57 |
| IO controller | 0 | 0 | 0 | 0 | ~9.5K, 4 + 8 (track RAM) |
| **Total** | **9,226 (40%)** | **6,419 (28%)** | **64 (76%)** | **24** | **~19K (78%), 76 (88%)** |

- The 9.5K LUTs and the 12 LSRAM are free, as estimated. `fdc` itself is 168 LUT, 177 DFF; its 512-byte shadow RAM is 8 uSRAM,
  no LSRAM. The 64 KB Z80 RAM is 32 LSRAM, the frame buffers 16.
- **Timing:** met. The 42 MHz core domain (`pll42`): worst slack +9.67 ns (slow_lv_ht, register to register; Libero's
  required period for that clock is 22.36 ns against 23.8 ns). Other clock domains of the base design: worst slack 3.3 ns and up.
- Left for the other machines: about 13.7K LUTs and 20 LSRAM, before any sharing of block RAM or moving RAM to DDR.

## Progress on the CP-400 (2026-10-31; the order the user set: CP-400, then DDR, then MSX2, then flash and test)

- **Gateware (Libero build 4307, package 0.6.0): builds, "Timing constraints have been met".** Machine select in CTRL b5:4 (0 CP-300,
  1 CP-400), ID `0x43503003`. `syn/beaglev-fire/cp400/`: `cp400_core.vhd` (the board-independent part of CP400_COLOR_FPGA's
  platform) with `cpu09`, `mc6883`, `mc6847`, `pia6821` (patched copies: single 42 MHz clock plus enables instead of the gated
  and pulse "clocks"; Altera RAM/ROM megafunctions replaced by inferred ones), `cp400_chargen`, `cp400_linebuf`.
- **Clock:** the original runs at 57.27 MHz with a 14.318 MHz enable. Here the 42 MHz core clock with an enable of exactly 15/44
  of it, so the machine has real NTSC speed. The CPU enable is combinational at the first clock of E (the SAM takes the CPU
  address on the next 14 MHz tick; a registered enable was two clocks late and corrupted every 15th RAM write).
- **RAM:** the 64 KB block RAM is shared with the CP-300 (one machine runs at a time), now with separate read and write addresses; the
  CP-400 writes once, at the end of the SAM's write pulse (as the SRAM of the original latches).
- **ROMs:** Color BASIC and Extended BASIC, 8 KB each, loaded by the daemon (not in the bitstream). The cartridge line is held high
  (no cartridge); with the original's `CART = Q` the ROM took FIRQs and restarted forever.
- **Picture:** `bvf_fb` has a CP-400 mode: 256 x 192, 4 bits per pixel (11 colours), 24 KB, one buffer: the host sets `hold` (CTRL b6),
  waits for STATUS b6, reads words 0-6143, clears `hold`. Tested in `sim/tb_fb4.v`.
- **Verified in simulation** (ModelSim of Libero, `sim/run_cp400.sh`, CP400_COLOR_FPGA's own ROMs): the CPU boots, the RAM test runs, and
  after about 2.5 s emulated time the screen shows "COLOR BASIC V1.0 / PROLOGICA 1984 / OK"; typing H and I on the CoCo matrix
  (`bit = 8 * column + row`) puts "HI" on the screen. The picture came through the real capture path (6847 VGA output).
- **Daemon and page:** `POST /api/ctrl {"machine":"cp400"}`, `PUT /api/rom/cp400bas` and `/api/rom/cp400ext`, frame message type 3
  (zlib of the XOR of the 24576 byte frame), machine selector, CoCo key map and on-screen keyboard. `host/test_cp300d.py` covers it.
- **Checked on the board (2026-10-31, package 0.6.0):** flashed, gateware `2025.10-13-g943f37f-4307-CP300` loaded, the CP-300 still runs;
  after uploading Color BASIC and Extended BASIC and switching the machine, the CP-400 shows "COLOR BASIC V1.0 / PROLOGICA 1984 / OK" with
  the blinking cursor, and `PRINT "HELLO FROM THE BOARD"` typed through the page runs. The user confirmed it works. The page shows about
  12 fps for the CP-400 (the CP-300 shows 38): the 24 KB frame read plus hold, then zlib of the XOR, in Python; the machine itself runs at full speed.
- **MiniIDE (gateware 4308, package 0.7.0): builds, timing met (+5.2 ns); the real HDB-DOS 1.4 LBA cartridge runs in ModelSim.** In the simulation the
  DOS identifies the drive (with the daemon's identify block; with a nearly empty one it prints "LBA HARD DRIVE NOT FOUND"), reads its
  sectors and reaches "OK". Cost: `bvf_ide` 461 LUTs, 182 DFF, 2 LSRAM; the cartridge ROM 4 LSRAM. Totals: **14,476 LUTs (63%), 79 of 84 LSRAM (94%)**.
  Only 5 block RAMs are left: the DDR step has to free the 64 KB RAM and the frame buffer before anything else fits.
  Not yet tried on the board.
- **MiniIDE (details):** `rtl/bvf_ide.v` is a small ATA device (PIO, LBA28; read, write, identify, diagnostic; the rest
  accepted and ignored) at `$FF50-$FF5F` with the 16 bit data latch at `$FF58`, replacing the OCIDE core and SD card of the original. The
  sector I/O is the daemon's: registers IDE_REQ 0x50, IDE_LBA 0x54, IDE_ACK 0x58, IDE_CFG 0x5C (disk and cartridge present, kept while the
  core is held), a 512 byte window at 0x40000, STATUS b4 = pending, and the interrupt. The cartridge ROM (8 KB, words 4096-6143 of the ROM
  window) is optional; with it the CART line carries Q again (as a real cartridge), without it the line stays high. Daemon: `ide0.img`
  in `/var/lib/cp300` used in place, `PUT/GET/DELETE /api/ide`, `PUT /api/rom/cp400cart`. Tests: `sim/tb_ide.v` (24 checks),
  `ide_tests()` in `host/test_cp300d.py`, and `sim/run_cp400.sh` with `CART=1` (the real DOS ROM on the full CP-400).
- **MiniIDE on the board (2026-10-31): the DOS says "LBA HARD DRIVE NOT FOUND" with the user's real image (507 MB NitrOS-9 disk, 990,976 sectors) in 0.7.0/0.7.1.**
  Found with a register poller on the board (`/tmp/idewatch2.py` style, reading STATUS/IDE_REQ/IDE_LBA/IDE_ACK in a loop): the DOS's IDENTIFY request stayed
  pending for **166 ms** before the daemon answered. The daemon's single loop was busy with the 24 KB CP-400 picture (hold, read, XOR in Python, zlib, send); the
  original answers IDENTIFY from a ROM in microseconds and the DOS gives up after a short wait. In simulation, with the same identify block (`sim/ide_identify_real.txt`)
  and the real sectors (`sim/ide_sectors.txt`), the DOS boots to OK, so the gateware is right. Fix in 0.7.2 (software only): `pump()` does only the disk requests
  (2 ms wake-up at most, interrupt first); `media()` does picture, audio and saving, with the register reads, XOR (as big integers) and zlib in threads.
  If it is still too slow: answer IDENTIFY in the gateware (a 512 byte identify RAM loaded by the host once), no host round trip at all.
- **Second cause, found with the board (same day):** with the latency fixed (answer in 2-5 ms) the DOS still said not found: the **identify request reads
  as kind 0 on the bus** (register IDE_REQ), a read request reads 1. Bit 2 of `kind` (identify was 3'b100) never shows on the board, although the
  simulation of the same RTL (also over the register bus, `sim/tb_idebus.v`) shows 4; the synthesised netlist has the flop (`kind[2]`, with an enable and a
  synchronous clear). Cause not found. Found by running the DOS's steps by hand from CP-400 BASIC (`POKE 65366,224: POKE 65367,236` = $FF56 / $FF57; `PEEK`
  of `$FF57` gave 88 = $58 and all identify words were 0: the daemon had ignored a request of kind 0). Work-around in 0.7.3: the daemon treats kind 0 (and 3, 4)
  as identify; the RTL now encodes identify as 3 (read + write: no command is both), so the next gateware does not use bit 2. **A BASIC session on the board is a
  good bus probe for the IDE registers** (`$FF50-$FF58`).
- **Third cause: the word order of the data port (2026-10-31).** With the identify fixed the DOS finds the drive and `DIR` works, but the names are scrambled. The
  ModelSim run of the DOS on the user's real sectors (`TYPE_TEXT='DIR!' ... sh sim/run_cp400.sh`, sector file `sim/ide_sectors*.txt`, identify `sim/ide_identify_real.txt`)
  prints **exactly the screen of the board**, both for the file order (package 0.7.3) and for the pairs swapped (0.7.4), so the simulation is the oracle: no board
  needed to iterate. The scrambling is a fixed rule (the DOS stores the pair [$FF50 read of iteration j+1, $FF58 read of iteration j]); inverting it, the window has to hold
  word k = {high b[2k+1], low b[2k-2]} (the low byte one word behind). With that order the DOS in simulation reads the directory chain and starts the disk's AUTOEXEC
  (`sector_words()` in `cp300d.py`, package 0.7.5). Tried and rejected: swapping the pairs (0.7.4), and a one-access delay in the gateware (`rbyte` pipeline: the DOS
  then reads the same sectors with the raw order, but the unit tests and the rule above say the daemon-side order is equivalent for whole-sector reads). The original's
  `ide_d_o` / `ide_d_r` path (platform.vhd GEN_IDE) is the source of the lag; modelling it exactly in `bvf_ide.v` is the clean fix and the only way to get writes.
  **Verified on the board (2026-10-31): the user's disk image (OS-9 with SideKick by Felipe Antoniosi, 507 MB) boots with 0.7.5.**
  **Sector writes are refused (ABRT) in 0.7.5** until the write side is worked out: the last byte pair cannot be recovered from the lagging low bytes.
- **Power cycle (gateware 4311, package 0.9.0).** Reset, Run and Stop all keep the RAM (as the real machines' RESET does): a game could not be left, because every
  restart found its state in memory. `CTRL` b7 (COLD, a pulse) starts `rtl/bvf_ramclr.v`: it writes zero to all 65536 bytes of the shared RAM (65536 clocks, 1.6 ms) and
  holds every machine and the disk handshake in reset meanwhile; then the machine starts from nothing. `{"cold":1}` on `/api/ctrl`, the page's *Power cycle* button.
  It works for whichever machine is selected (the RAM is shared; the MSX2's VRAM in the same pool is cleared too, its DDR RAM will need its own clear). Test:
  `sim/tb_ramclr.v`.
- **Power switch (software 0.9.1, same gateware 4311):** the old *Run/Stop* was only a second RESET (stopped = held in reset, run = released: the machine starts at the
  reset vector, the daemon reloads the ROMs), so it is gone. The page has **Reset** (keeps the RAM), **Power** (off = held, black screen; on = RAM cleared, ROMs loaded,
  machine starts) and the daemon takes `{"power":0|1}` (`run` and `cold` are accepted as old names). Switching machines and uploading the last ROM are power-ons.
- **Not in the CP-400 yet:** floppy disks, cassette, joysticks (centred), serial.

### Resource split of the build with both machines (4307)

| Block | 4LUT | DFF | LSRAM | uSRAM |
|---|---|---|---|---|
| Board base (processor subsystem, M.2/PCIe, clocks) | 2,919 | 2,835 | 2 | 16 |
| CP-300 machine | 3,986 | 1,234 | 13 | 0 |
| **CP-400 machine** (`cpu09` 2,942, `mc6883` 264, `mc6847` 272 + char ROM 271, PIAs 189, ROM RAMs, glue) | **4,275** | 955 | **8** | 0 |
| 64 KB RAM and glue (`core/Primitives`) | 1,209 | 1,154 | 32 | 0 |
| Host interface (frame capture 702, registers 361, sector service 170, audio 114, bus 13) | 1,360 | 1,077 | 17 | 8 |
| **Total** | **13,737 (60%)** | **7,432 (32%)** | **72 (86%)** | 24 |

- Timing: the 42 MHz domain has +5.2 ns worst slack (was +9.7 ns with the CP-300 alone); the other domains are unchanged.
- **Room left:** about 9.2K LUTs and **12 LSRAM**. The LSRAM is what limits the MSX2: its VRAM (64 KB = 32 LSRAM, 128 KB = 64) needs the
  64 KB machine RAM and the frame buffer (together 48 LSRAM) out of block RAM first, which is the DDR step.
- `cpu09` is the single biggest block of the whole design (2.9K LUTs, as large as the CP-300's Z80, video and floppy together).

## Progress on DDR (2026-10-31; gateware 4310, package 0.8.0)

- **What is there:** `rtl/bvf_ddr.v`, a **probe**: an AXI4 master (64 bit data, 38 bit address) on the fabric-to-processor port of FIC0
  (`BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_TARGET`, clock `FIC_0_ACLK`), with registers at 0x60-0x94 of the window. It reads and writes the DDR and
  measures the latency (ACLK cycles, min / avg / max), the burst bandwidth, and checks data (write, read back, compare). Run
  `python3 host/ddrprobe.py` on the board (`--addr 0xC8000000`, the 32 MB reserved-memory region `buffer@c8000000` of the stock device
  tree: the non-cached view of DDR, unused by Linux; `buffer@d8000000` is the write-combining one, `buffer@88000000` cached). Run it
  again with the board busy to see the latency under load. `sim/tb_ddr.v` tests the probe against an AXI slave model.
- **The cape connection** (`gateware/make_cape.py`): the cape HDL gets `ACLK`, `ARESETN` and `AXI_M_*` ports; `ADD_CAPE.tcl` connects
  them to `FIC_0_AXI4_TARGET` signal by signal (`sd_clear_pin_attributes` first, then `sd_connect_pins` on
  `BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_TARGET_FIC_0_AXI4_S_<signal>`). A bus-interface connection (HDL core BIF `AXI4:AMBA:AMBA4:master`) is
  refused by SmartDesign as "not compatible", and `sd_show_bif_pins` is not needed.
- **Built:** 16,036 LUTs (70%), 79 of 84 LSRAM, timing met (42 MHz domain +4.9 ns, the FIC clock domains +2.7 ns). The probe costs about 1.5K
  LUTs (64 bit result and statistics registers): it is for measuring and will be trimmed.
- **Not known until the board runs it:** whether FIC0's fabric-to-processor port is enabled in the MSS configuration (the probe tells:
  it gets no answer and `ddrprobe.py` aborts it), the ACLK frequency (measured by the probe), and the latency and bandwidth.
- **What the numbers decide:** the MSX2's main RAM and ROMs in DDR (its Z80 takes wait states: a 3.58 MHz machine cycle is 840 ns, so a read
  latency of a few hundred ns fits in one cycle or one wait state). The CP-300 and CP-400 stay in block RAM (the 6809's SAM fetches
  video every 14 MHz tick: DDR latency would stall the machine). The block RAM left (5 LSRAM) cannot hold the MSX2: its VRAM (64 KB =
  32 LSRAM, 128 KB = 64) can share the 64 KB RAM that the CP machines use, but its main RAM and ROMs have to be in DDR.
- **Linux side, later:** the daemon loads the MSX2's ROMs into the reserved region through `/dev/mem` or a udmabuf (the framework's
  SmartHLS overlay has `udmabuf-overlay.dtso` for `dma_non_cached_low`); not written yet.

## MSX2: the source and the plan (2026-10-31)

- **Source:** KdL's OCM-PLD, cloned (the user agreed to the download) into `C:/Users/roniv/Dev/github/ocm-pld-dev` (`github.com/gnogni/ocm-pld-dev`,
  commit `226bcb6`; not part of this repository). Licence: ESE Artists' factory, redistribution allowed with the notices, **not to be sold or used in
  a commercial product or activity** (settled with the user; keep the headers, say it in the README and the package). Layout: `esemsx3/src/emsx_top.vhd`
  (3,056 lines: the whole machine, slots, mapper, SCC, kanji, SDRAM controller), `cpu/` (T80), `video/` (the V9958 VDP, 16K lines in total with the
  peripherals), `sound/` (PSG, SCC, OPLL), `peripheral/` (keyboard, RTC, MegaSD, UART, ...), `firmware/`, `docs/`.
- **How it is built:** a 21.477 MHz base clock (+ a 4x PLL for the SDRAM), the Z80 at 3.58 MHz, the VDP on `CLK21M`; **everything, main RAM (a 4 MB mapper),
  the ROMs, kanji, MegaROM/SCC and the VDP's VRAM, sits in one 32 MB SDRAM** behind the controller in `emsx_top.vhd` (lines ~2400-2700); the VDP's VRAM
  bus (`pRamAdr[16:0]`, `pRamDbi[15:0]`) is slot-scheduled by that controller.
- **What has to change** (the part of the FPGA that is not portable): (1) the clock: 21.477 MHz is exactly 45/88 of our 42 MHz core clock, so the
  machine runs on the 42 MHz clock with an enable (as the CP-400 does with 15/44), or on a second PLL output; the VDP and the sound take
  `CLK21M` as a real clock, so either every process gets the enable or the machine gets its own clock domain. (2) the memory: **VRAM on chip, main
  RAM and ROMs in DDR with Z80 wait states.** The VDP cannot take DDR latency (it fetches every few dot clocks), the Z80 can (a machine cycle
  is 840 ns). (3) the peripherals: keyboard from the host (the page sends a matrix), no SD card / UART / WiFi / MIDI (the host is the storage),
  disks through the daemon (a later step), no EPCS / IPL ROM: the BIOS images are loaded by the host.
- **Block RAM budget:** 79 of 84 LSRAM are in use. The MSX2 needs 64 KB of VRAM on chip (32 LSRAM) at least (64 KB is allowed by the MSX2 standard;
  128 KB, 64 LSRAM, is what screens 7 and 8 and many games want). The only way with the current budget is to **share the 64 KB RAM of the CP machines
  with the MSX2's VRAM** (one machine runs at a time). 128 KB of VRAM needs more: the frame buffer shared as well (CP-300 uses 12 KB of it, the CP-400
  24 KB; the MSX2 would read its picture from the VDP's output the same way) and still does not fit; so 64 KB of VRAM first.
- **Milestones:** M1 the Z80 + VDP + PSG + slot logic with a 64 KB RAM and a BIOS in block RAM, simulated with the OCM's own BIOS (a text screen);
  M2 the clock and the VRAM sharing in the bus, the picture through the frame capture (4 bit colour, 256 x 212 / 512 x 212 as the VDP gives
  it), the keyboard; M3 main RAM and ROMs in DDR with wait states (needs the DDR probe's numbers and the loader in the daemon); M4 sound
  (PSG, then SCC / OPLL if the area allows), the page, a package; M5 disks and the rest. The **DDR probe (package 0.8.0) should be run first**: M3 depends
  on whether FIC0 answers and on the latency.

## Done for step 1

- The gateware builds and meets timing.
- The simulations and `host/test_cp300d.py` pass.
- The per-module resource split is reported (4LUT, DFF, LSRAM, timing).
- A package is built.
- `HANDOVER.md`, `README.md`, `BUILDING.md` and the technical paper are updated where the design changed.
- Stop there and report to the user before step 2.

## DDR probe result (board, gateware 4311, 2026-10-31)

FIC0 AXI4 master to DDR at 0xC8000000 works (resp OKAY, write + read back + compare of 1000 words: 0 errors). ACLK 125 MHz.
One read: 32 ACLK = 256 ns (min 26, max 136 = 1088 ns). One write: 8 cycles = 64 ns (avg 186 ns over 1000, max 520 ns).
Bursts of 16 words: 2.88 cycles per word, 347 MB/s.
Consequence for the MSX2: a Z80 memory cycle at 3.58 MHz is about 840 ns, so a 256 ns read (start the request when the address is
valid) fits in one cycle; the rare 1 us outliers need a wait state (WAIT_n). Main RAM, ROMs and mapper can live in DDR.

## FreHD command interface (gateware 4312, package 0.10.0)

The FreHD pack's boot disks (m3-4p-frehd-boot: "LOADING FREHD ROM. LOVE, -TJBCHRIS...") talk to the FreHD board's second
interface, which the WD1010 emulation (ports C8-CF) did not have: COMMAND2 C4, DATA2 C2, SIZE2 C3, ERROR2 C5, and CF's status while a
command runs (veco/FreHDv1 sw/trs_hard/interrupt.asm + trs_extra.c, sw/z80/frehd_rom/loader.asm). They read FREHD.ROM from the SD
card (open, read 256 bytes at a time, close), list the card and mount hard disk images.
- `rtl/bvf_frehd.v` sits on the core's expansion bus (`exp_*`, free until now), so the shared rtl (ht1080z, wd1010) is untouched. Registers
  FRH_REQ 0x98, FRH_ACK 0x9C, window 0x50000 (word n = byte n), STATUS b1 = command pending (also in the interrupt). `sim/tb_frehd.v`.
- `host/frehd.py` is the PIC firmware's command set over a folder (`/var/lib/cp300/sd`): version, time, open/read/write/seek/close,
  opendir/readdir (FatFS FILINFO), mount (an .hdv from the folder into hard disk 0/1), infodrive, read header. `PUT/GET/DELETE /api/sd`.
- The boot sector of the FreHD boot disks first does the board's ROM trick (found on the board with `host/frhwatch.py`: no command ever
  came): `out (C5),3; in a,(C4); cp FEh; ... inir` reads FEh and the 255 byte loader (loader_eeprom.asm) from C4, byte 2 = the value
  written to C5, then jumps to 5000h. 4312 lacked it ("ERROR LOADING FREHD ROM" came from the boot sector itself); added to bvf_frehd.v (gateware 4314).
- Not done: IMAGE (JV1/JV3/DMK from the card), boot loader (firmware update).
- Same limit as before on the other ports (DE0, Pocket, MiSTer, Tang): see the notes of 2026-10-31 in the CP-300_FPGA repo; the block
  is portable, the host side is the port's IO controller firmware (fat.c) or the Pocket's data slots.

## MSX2 M1 done (simulation, 2026-11-01) and the VRAM budget

- **M1:** `msx2/msx2_core.vhd` + `msx2/ocm/` (OCM VDP, PSG, clock enable ENA21 = 45/88 of 42 MHz, see `msx2/README.md`), bench `sim/run_msx2.sh`
  (`ROMKIND=cbios|a1wsx|test|test2|test3`). C-BIOS shows its logo; screen 5 and screen 7 byte ramps display bit-exact; interrupts counted = frames.
  The core's VRAM port is the full 128 KB (17 bit address: word index = adr(15:0), byte lane = adr(16); modes 0-5 use lane 0 only,
  screens 6-8 both lanes). Every RAM that the VDP uses must follow `ena21` (adjacent enables).
- **VRAM 128 KB on chip: the arithmetic (the user wants 128 KB, "share the pool").** LSRAM blocks of 20 Kbit, geometry 2K x 10 / 1K x 20.
  Used while the MSX2 runs by nothing else, and owned by this repository's RTL (not the shared `rtl/` of the other ports): `ram64` 32 (64 KB x 8),
  frame buffer 16 (repacked as 6144 x 32 bit from 2K x 10 blocks: 12), cartridge ROM 4, CP-400 ROM RAMs 8, `bvf_ide` 2, free 5: **a pool of 63 blocks
  at best** (the MSX2's frame goes to DDR instead of the frame buffer). The CP-300's own 13 blocks live in the shared `rtl/ht1080z` / Pocket core and
  are not touched.
  - Natural mapping (word = 16 bit = 2 blocks of 8 used bits): 64 blocks. **One block short** and at ~100% of the chip: not buildable.
  - Packed (5 words of 16 bit in 8 blocks of 2K x 10, row = adr(10:0), slot = adr(15:11) -> group = slot / 5, field = slot mod 5): 56 blocks. Fits the pool
    (7 spare) but a write of one byte is a read-modify-write of an 80 bit row (sub-block bit ranges): needs a second read port (true dual port) or a
    two-tick write; LSRAM write byte enables are not reachable through inference.
  - Other ways: 64 KB VRAM only (lane 0 = exactly the CP RAM, 32 blocks, no screens 6-8); upper 64 KB in DDR with prefetch; or free blocks in the shared
    CP-300 core (not allowed: other ports must not change).
- Not started: the pool itself (`bvf_core_bus.v` `ram64` and `bvf_fb` become views of one block array), the MSX2's frame capture to DDR, the keyboard.

### Packed VRAM verified in simulation (2026-11-01)
`msx2/msx2_vram.vhd` (128 KB in 56 blocks of 2K x 10, byte write = read-modify-write at the second ena tick of the VDP's three-tick write) drives the VDP in
`sim/tb_msx2.vhd` (`USE_PACKED`, default): C-BIOS reaches the same text screen as with the plain model (`sim/msx2_m1_packed_text.png`, frame 330), and the packed
and plain contents agree on every tick once the CPU has stopped writing (0 of 1.28 M). The two differ for one or two ticks just after a write; the VDP never reads
the word it is writing in that slot. Next: the pool in `bvf_core_bus.v` (`ram64` + `bvf_fb` + cartridge ROM become blocks of one array, 63 available vs 56 needed),
the MSX2's frame capture to DDR, the keyboard, a Libero trial for the block count.

## MSX2: state at the end of the session (2026-11-01) and how to continue

### What exists (branch `feature/remove-io-ctrl`, nothing pushed)
- **Package 0.11.0** (`releases/cp300-beaglev-fire-0.11.0.tar.gz`, gateware 4313, id `2025.10-13-g943f37f-4313-CP300`): **CP-300 + MSX2, no CP-400**.
  Synthesis: 16,817 LUTs (19,985 with the RAM interface logic after P&R, 87%), **76 of 84 block RAMs**, 30 uSRAM, timing met. **Not tried on a board.** Package 0.10.0
  (gateware 4312, CP-300 + CP-400, built before the pool) is untouched. The pool changed the CP RAM / frame buffer / cartridge ROM RTL, so a rebuilt CP-300 + CP-400
  gateware (`make_cape.py --variant=cp400`, macro `BVF_NO_MSX`) is **not built and not verified on a board**.
- **Why two gateware variants:** all three machines together need 24,702 LUTs (chip: 22,956) and 87 block RAMs (84). The MSX2 costs ~8.7K LUTs: T80s 2,593,
  VDP 2,595, PSG 497, `bvf_pool` muxes 1,600, ~500 for capture and the DDR engine, plus block-RAM interface logic of ~36 LUTs per block (the 56 VRAM blocks: ~2K).
- **Sources** (under `syn/beaglev-fire/`):
  - `msx2/msx2_core.vhd`: Z80 (T80s), VDP, PSG, OCM slot layout, PPI, 4 MB mapper (`MAP_BITS = 8`), expanded slot 3.
  - `msx2/ocm/*`: generated by `msx2/port_ocm.py` from KdL's OCM-PLD (clock enable `ENA21` = 45/88 of 42 MHz on every clocked process and on the small RAMs, VGA scan doubler removed, licence headers kept).
  - `msx2/msx2_vram.vhd`: the packed VRAM as a simulation reference.
  - `rtl/bvf_pool.v`: the block RAM pool; the VRAM packed into 56 blocks, byte writes by read-modify-write.
  - `rtl/bvf_msxmem.v`: DDR engine (Z80 byte access + capture writer on one AXI master).
  - `rtl/bvf_msx.v`: core + glue + picture capture.
  - `rtl/bvf_core_bus.v`: machine 2, AXI mux with the probe by `own = run & m2`, `KEYS2`. `rtl/bvf_regs.v`: KEYS2 at 0x20.
  - `host/cp300d.py` + `host/web/index.html`: machine msx2, ROMs to DDR through the probe, picture from `/dev/mem`, 88-bit key matrix.
  - `package/MSX2-LICENSE.txt`, `README.md` (MSX2 section), `BUILDING.md`.
- **Memory map** (DDR at $C800_0000): mapper RAM $000000-$3FFFFF; main ROM (32 KB) $620000; sub ROM [+ ext/kanji, up to 48 KB] $630000; page-2 slot-0 ROM $63C000;
  picture capture $C900_0000 (684 x 262 bytes RGB 3-3-2, 1024 per line, frame counter in the FRAME register). The host loads the ROMs while the machine is held (`CTRL.run = 0`: the probe owns AXI).
- **VRAM:** 128 KB = 64K words x 16 bit (word = adr[15:0], byte lane = adr[16]); 5 words per 80-bit row of 8 blocks (2K x 10), slot = adr[15:11], group = slot / 5.
  It uses the CP machines' RAM (32 blocks), frame buffer (12), cartridge ROM (4) and 8 own blocks. The CP-400's two 8 KB ROM RAMs are NOT in the pool (they could be: 8 blocks saved).

### Verified in simulation (ModelSim: `sim/run_msx2.sh`, `run_msxsys.sh`, `run_pool.sh`; Icarus: `sim/run.sh`)
- C-BIOS MSX2 shows its logo and its text screen (frame 330, ~5.5 s emulated); screen 5 and screen 7 byte ramps are bit exact; the interrupt count equals the frame count.
- The pool equals plain arrays in both modes; `bvf_msxmem` works against an AXI slave with random latency (0 errors).
- The integrated machine (`tb_msxsys.v`: Z80 runs the ROM from the AXI model, VRAM in the pool, capture to the AXI model) draws the screen-7 ramp.
- CP-300/CP-400 host-side regressions (`sim/run.sh`) pass; the CP-400 core runs 3 frames (no full boot to the BASIC prompt checked).
- Simulation speed: ~35 s real per 60 ms emulated. ROMs for the bench: `gen_msx2_rom.py` (`cbios`, `a1wsx` = the user's FS-A1WSX set from `~/Documents/openMSX/share/systemroms/machines/panasonic`
  (copyrighted: never commit), `test`, `test2`, `test3`).

### NOT verified (do these first on the board)
1. Flash 0.11.0 (the user flashes: `sudo ./install.sh`), upload the ROMs (main 32 KB, sub 16-48 KB), power on. Expect a BIOS banner within seconds (effective Z80 speed ~2.5 MHz: every read waits for DDR).
2. Whether `/dev/mem` can read `0xC9000000` (reserved region) for the picture, and whether the probe-based ROM load works (`cp300d.py ddr_write`, ~10K 64-bit writes).
   If `/dev/mem` is refused, the picture needs another route (udmabuf, or the probe's read mode).
3. Keyboard matrix, audio levels (the scaling in `index.html` is a guess), VDP interrupt/status timing with real software, the 4 MB mapper detection time (`MAP_BITS = 6` gives 1 MB).
4. The DDR path under Linux load (latency outliers up to 1.1 us are covered by WAIT, untested).
5. The rebuilt CP-300 + CP-400 gateware: build `--variant=cp400`, run `sim/run_cp400.sh 90` to the prompt, test on the board before replacing 0.10.0.

### How to build (read `BUILDING.md`, plus these lessons)
- **Use your own framework copy** (this session: `D:\bvf\gw943m`, `D:\bvf\run_gw943m_4313.ps1`). The shared `D:\bvf\gw943` is used by other sessions and the `run_*.ps1` scripts delete `work\libero` and `build` first.
  The **Synplify licence is node-locked: one Synplify (one build) at a time on the machine**; builds from different sessions must be serialised.
- `python syn/beaglev-fire/gateware/make_cape.py D:/bvf/gw943m --variant=msx2` (or `cp400`), then `powershell -NoProfile -ExecutionPolicy Bypass -File D:/bvf/run_gw943m_4313.ps1`
  (~12-15 min; the log is written only at the end). The framework's `BUILD_BVF_GATEWARE.tcl` needs `configure_tool -name {SYNTHESIZE} -params {AUTO_COMPILE_POINT:false}` before `run_tool -name {SYNTHESIZE}`:
  with automatic compile points Synplify crashed (`Signal 011 in m_generic.exe`) loading a compile point's interface model. (`syn_hier` attributes on the VHDL entity did not stop the compile point.)
- Overlay image: `wsl -d Ubuntu-24.04 -- bash -c "cd /mnt/d/bvf/gw943m && mkdir -p out && PYTHONPATH=/mnt/d/bvf/gw943m python3 /mnt/d/bvf/gen_dtbo_4313.py"`
  (the script sets the identity string `2025.10-13-g943f37f-<DESIGN_VERSION>-CP300`). Copy `out/mpfs_dtbo.spi` next to `mpfs_bitstream.spi` in `build/bitstream/LinuxProgramming`, then
  `package/build_package.py --gateware <build/bitstream> --out releases --version 0.11.0`. Raise `DESIGN_VERSION` and the identity for every gateware release (4313 = 0.11.0 is used).

### Open items, in the order I would take them
1. **Board test of 0.11.0** (above); fix what it shows.
2. **All three machines in one bitstream** needs ~4K fewer LUTs. Options with estimates: VRAM 64 KB on chip (-1.9K, no screens 6-8); trim the DDR probe to single reads/writes (-1.2K);
   pool restructure (-0.5..0.8K); a smaller Z80 (-0.3..0.6K); VDP feature cuts (-0.3..0.6K). Also move the CP-400 ROM RAMs into the pool (-8 blocks) to fix the 87 vs 84 block RAMs.
3. **Cached DDR VRAM** (best long term): 128 KB (or more) in DDR, a small cache (~4 KB in 64-byte lines, 2-3 block RAMs + a tag table), write-through; a miss stalls the whole MSX2
   (Z80, VDP, PSG share the clock enable) for ~0.45 us. It needs a combinational hit check so the enable can be gated within one clock (adjacent enables occur).
   Estimated slowdown: display scanning ~1% stall; typical software (BASIC, text, most games) not noticeable; VDP **blitter commands** (HMMM/LMMM/LINE/PSET in games that scroll or move big areas
   with commands, screens 5-8) and heavy sprite use (many sprites per line) several times slower than real hardware; CPU VRAM writes through port $98 are posted and unaffected.
   It frees ~3.4K LUTs and 56 blocks and costs the cache logic (~0.6K) and a lot of simulation.
4. **Speed:** a read cache in front of `bvf_msxmem` (instruction fetch is sequential: line prefetch) to get closer to 3.58 MHz; the OCM's turbo options need it even more.
5. **M4/M5 leftovers:** clear the DDR RAM at power on (not done); RTC; OPLL/SCC; the OCM's own BIOS (`OneChipMSX_DE0/bios_m2p`, needs its switched I/O ports 0x40-0x4F); disks (a host-served FDC like `bvf_fdc`,
   or a MegaSD/Nextor-style interface through the daemon); joystick ports (the PSG's are tied high).
6. Documentation not yet updated: the technical paper (`docs/beaglev-fire-technical-paper.md` carries the user's uncommitted edit: do not overwrite) needs the pool, the DDR memory engine, the variants and these numbers.

### Traps met on the way
- Z80 write cycle: act when `WR_n` ends, with address and data captured while it is low. During the interrupt acknowledge cycle (`M1` + `IORQ`) the bus must read $FF and memory must not answer.
- Every RAM the VDP uses must follow `ENA21` (two enables can fall on adjacent 42 MHz clocks).
- A VHDL entity with a generic became a compile point named after it: avoid generics on top-level blocks in the Libero flow.
- `make_cape.py` must stage the OCM files byte-preserving (UTF-8 comments); the bash tool eats backslashes in heredocs (write scripts with the Write tool).
- Shared machine: another session builds in `D:\bvf\gw943` and deleted a finished 4313 output once; the repo working copy is shared too (`docs/` technical paper and `test3mb.hdv` are not mine).

## Alice (machine 5) on the shared Z80 line (2026-11-01, branch `feature/alice-fpga`, from `feature/z80-machines`)

The Matra Alice (original Alice / MC-10, MC6847) is machine 5: the MC6803 runs as a C process on Linux (`alice/emu/alice_emu.c`), the
FPGA keeps the video: `bvf_mc1000` with `alice = 1` (the MC-1000's VDG with per-byte A/S and INV from the video data), the pool's VRAM,
the window `0x60000` (word n = 4 VRAM bytes) and the register `0xA0` (the `$BFFF` latch; b7 = sound). Register ID is now `0x43503004`
(`cp300d.py` `ID_VALUE`: a daemon and a gateware must be updated together). Daemon: `alice` machine, `PUT /api/rom/alice` (8192 bytes),
the emulator started and stopped with the machine, web page with the AZERTY keys. Simulated (MC-10 prompt, semigraphics, RG6:
`sim/run_z80sys.sh` with `MACH=5`); **not built as gateware and not run on the board**. Details and open points: `alice/README.md`.

## Tape and the MSX disk interface (2026-11-02, branch `feature/alice-fpga`, gateware 4322, package 0.13.0)

- **Tape, all machines** (`rtl/bvf_tape.v`, registers 0xA4-0xB0, `host/tape.py`, `TapeDeck` in `cp300d.py`, "Cassette" panel): a host-fed pulse FIFO
  (1024 entries: duration in us, hold bit) gated by the machine's motor line, and a timestamped edge recorder. Inputs/outputs per machine:
  CP-300 port $FF (in bit 7, out bits 1:0), CP-400 PIA1 PA0 / the DAC's top bit / CA2 motor, MSX1 PSG register 14 bit 7 / PPI C bit 5 / motor
  PPI C bit 4, ZX Spectrum port $FE bit 6 / bit 3, MC-1000 PSG port B bit 7 / port A bit 7, Alice in `alice_emu` (`alice/emu/alice_tape.h`, same
  entries over its stdin). Formats: .tap, MSX .cas (1200 baud), CoCo/MC-10 .cas/.c10 (1200/2400 Hz), TRS-80 .cas (500 baud), .wav (the page converts).
  Simulated (`sim/run_tape.sh`; the MSX1's cassette input counted by a Z80 in `MACH=6`); not tried on a board: the CAS timings (long/short header
  lengths) and the polarity the ROMs expect are from the formats' documents.
- **MSX1 disk interface** (slot 2 page 1, `bvf_msx1.v`): the CP-300's WD1793 (`rtl/fdc/wd1793.vhd`, new input `sec512`) is shared through a second bus
  on `ht1080z` (`xf_*`); the registers are the "National" layout (decoded from `expert_ddplus_disk.rom`'s accesses to $7FB8-$7FBC: status/command,
  track, sector, data; $7FBC read b7 INTRQ b6 /DRQ (low = ready), write b1:0 drive (one-hot: 1 = A, 2 = B) b2 side b3 motor); the 16 KB ROM is in the DDR window at $648000. The daemon's
  sector service answers with `RawDsk` images (512 byte sectors, `/api/msxdisk/<0|1>`, disk ROM `/api/rom/msx1disk`). `MACH=6` of `run_z80sys.sh`
  runs a Z80 test program through the controller (sector 3 of track 0, 512 bytes, PASS). Not tried with a real disk ROM on the board; other
  disk interface layouts are not implemented; FORMAT (WRITE TRACK) is not supported by the controller.
- Resources of gateware 4322: 21,432 LUT (93.4%), 80/84 LSRAM, timing met. The next machine will not fit without trimming (the DDR probe is
  worth about 1.2K LUT).
