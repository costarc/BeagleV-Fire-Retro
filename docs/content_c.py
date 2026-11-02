BLOCKS = [
    # ------------------------------------------------------------------------------------------------ 8
    ("h1", "8. Why the Alice uses a soft CPU instead of an FPGA core"),
    ("p", "Five of the six machines have a CPU inside the fabric: the shared T80s (four machines) and `cpu09` (the CP-400). The sixth, the Matra Alice, has its Motorola MC6803 **emulated in C on the board's Linux**. "
          "This is the decision most likely to look odd in an FPGA project, so this section gives the whole argument: what the machine needs, what the alternatives would have cost, what crosses the boundary, "
          "and what remains unproven."),
    ("h2", "8.1 What the machine needs"),
    ("table", ["Item", "Value", "Source"], [
        ["CPU", "MC6803, 3.579545 MHz / 4 = 894,886 Hz, no on-chip ROM", "MAME's `mc10.cpp` / `m6801.cpp`, checked by running the MC-10 ROM"],
        ["Instruction rate", "0.2 to 0.3 million instructions per second", "arithmetic from the clock and the 6801's cycle counts"],
        ["Memory", "4 KB RAM at `$4000`, 8 KB ROM at `$E000`, on-chip RAM `$80-$FF`", "MC-10 map"],
        ["Video", "MC6847 reading the RAM from `$4000`; per byte b7 = A/S, b6 = INV", "same chip as the MC-1000's and the CP-400's"],
        ["Sound", "one bit, `$BFFF` bit 7", "software toggles it: timing matters"],
        ["Keyboard", "8 columns × 7 rows, scanned through port 1 and read from `$BFFF`", "matrix in `alice/emu/alice.c`"],
    ], [2.4, 8.0, 6.6], "What the Alice needs."),
    ("h2", "8.2 The options"),
    ("table", ["Option", "Logic", "Block RAM", "What it takes", "Verdict"], [
        ["**A.** An MC6803 in HDL, in the fabric", "a 6800-family core with timer, ports and serial: of the order of 1.5 - 3K LUTs (estimate: the 6809 `cpu09` is 2.9K; no 6803 core was built)",
         "RAM (4 KB) and ROM (8 KB) would fit in the shared pool", "a new core to write or port, and to verify against a machine whose ROM behaviour we only know from MAME", "**No room in the logic.** Only 1.3K LUTs are free at the end."],
        ["**B.** The host as bus master of the CP-400's SAM (the first draft)", "small", "none", "the 6809 side is replaced by writes through the register window at the SAM's timing; changes to `cp400_core`; the SAM fetches video every 14 MHz tick",
         "Rejected: needs the exact SAM timing and touches a core that works."],
        ["**C.** CPU on the host, **video in the fabric** (chosen)", "**about 60 LUTs**", "none (the VRAM is the pool's)", "a C emulator, a VRAM window, one register, the MC-1000's VDG with two attribute changes", "**Chosen.**"],
        ["**D.** As C, but bare metal on one U54 hart (AMP)", "same as C", "none", "a boot-chain change (HSS payload or remoteproc); jitter drops further", "Later, if C's sound jitter is not good enough."],
    ], [3.4, 3.8, 2.4, 4.6, 2.8], "The ways to give the Alice a CPU."),
    ("fig", "fig10_softcpu.png", "Left: the logic budget. After the six-machine gateware 1,297 LUTs are free; the smallest CPU already in the design costs 2.3 to 2.6K. Right: the host's load. "
                                 "The PC figure is measured (best case, a spinning ROM); the U54 figure is an estimate and has not been measured.", 16.5),
    ("h2", "8.3 What crosses the boundary, and what does not"),
    ("p", "The whole argument for C rests on one number: **nothing crosses the FIC per 6803 cycle.** The emulator keeps the CPU, the RAM, the ROM and a shadow of the video RAM in its own memory. After each slice of about 1 ms of machine time it writes "
          "the VRAM words that changed (a full 6 KB redraw is 1,536 posted writes of 32 bits) and, right after the instruction that stored it, the `$BFFF` latch. The key matrix it reads from the existing `KEYS` registers once per slice."),
    ("table", ["Direction", "What", "How"], [
        ["host → fabric", "the video RAM, `$4000-$57FF`, 6 KB", "window `0x60000`: word n = bytes 4n..4n+3; the gateware writes the four bytes into the pool's VRAM port one per clock (`ALICE` b8 = busy)"],
        ["host → fabric", "the `$BFFF` latch: DAC bit, CSS, A/G, GM0-2 / INT-EXT", "register `0xA0`, written right after the instruction that stored it"],
        ["fabric → host", "the key matrix", "`KEYS_LO/HI`, bit = 8 × column + row"],
        ["fabric internal", "sound", "`{al_mode[7], 8'h00}` into the shared audio FIFO: the gateware timestamps the edge at the register write"],
    ], [2.6, 5.4, 9.0], "The Alice's interface to the host."),
    ("p", "The fabric half is the MC-1000's video: its MC6847 generates its own video addresses, so no part of the CP-400 core changes and no SAM timing is involved. Two things differ and are done by parameter: the Alice keeps its attributes in the video data "
          "(b7 = A/S, b6 = INV; the MC-1000 keeps INV in b7), and the VDG's mode comes from the latch instead of from an I/O port. The character ROM, semigraphics-4 colours and the frame path are shared."),
    ("h2", "8.4 Why this is better than it looks"),
    ("ul", [
        "**It is testable before any gateware exists.** The emulator was developed and tested on a PC: 93 hand-computed checks (flags of every ALU group, 16-bit operations, MUL, DAA, stack and interrupt frames, timer flags, ports) and a sweep of all 256 opcodes against an independently written table. "
        "The MC-10 ROM reaches `MICROCOLOR BASIC 1.0 / OK` in 3 s of machine time and runs `PRINT 1+1`. A ROM that exercises most addressing modes (the 16 KB Alice 32 ROM) runs 5 s with 0 illegal opcodes.",
        "**The fabric half is small enough to simulate completely.** ModelSim runs the real `bvf_core_bus`, the pool, the VDG and the frame capture from a VRAM + mode image produced by the emulator: the MC-10 prompt, semigraphics-4 and RG6 graphics appear (`sim/alice_*.png`). "
        "The real-time runner against a register array on the PC produces a VRAM image byte-identical to the harness's after 3 s.",
        "**The speed is not a question.** 165 million instructions per second on a PC in the best case (500 × real time); about 2 to 5 % of one U54 hart by estimate.",
        "**The code is structured for the other option.** The CPU file has no dependency (no malloc, no libc) and talks to its machine through bus callbacks; the platform layer is meant to shrink to four calls (VRAM flush, mode, DAC, keys; not yet written), so the same code could later run bare metal.",
    ]),
    ("h2", "8.5 What is not known"),
    ("ul", [
        "**Not run on the board.** The hardware mapping of the emulator (`mmap` of the UIO window) was not compiled on the PC (Windows has no `sys/mman.h`); the installer compiles it on the board.",
        "**Sound jitter.** The sound edge is timestamped when the register write arrives, so the jitter is that of one FIC write (a few microseconds) plus Linux scheduling of the emulator process. Pinning to a core with `SCHED_FIFO` is not done and the effect on a 1-bit sound has not been measured.",
        "**Field sync.** The MC-10 ROM ran to its prompt without the 6847's field sync on the CPU's interrupt; whether the Alice's ROM needs it is open.",
        "**The Alice 32 / 90** (EF9345 video) is a different machine and out of scope. The original Alice ROM has not been run; only the MC-10's (the same hardware).",
    ]),
    ("note", "**When is a soft CPU the right answer?** When (1) the CPU needs a few percent of one core, (2) its traffic to the rest of the machine can be batched (here: changed VRAM words and one latch, not a bus cycle), (3) the hard-real-time parts "
            "(video generation, sound edges) are separable and stay in the fabric, and (4) area is the scarce resource. All four held for the Alice. None would hold for the Spectrum, whose ULA steals memory cycles from the Z80 with clock-level timing."),

    # ------------------------------------------------------------------------------------------------ 9
    ("h1", "9. Why the video memory must be on the chip, and what the MSX2 taught us"),
    ("h2", "9.1 The rule: the CPU may wait, the video may not"),
    ("p", "Before any machine memory was moved off the chip we built a probe (`bvf_ddr`, V4): an AXI master on FIC0 that reads and writes DDR and measures its own latency. The board's numbers, with Linux running:"),
    ("table", ["Measurement", "Result"], [
        ["ACLK (the AXI side)", "125 MHz"],
        ["One 64-bit read", "32 ACLK = **256 ns** typical; minimum 26 (208 ns), **maximum 136 (1,088 ns)**"],
        ["One 64-bit write", "8 ACLK = 64 ns; average 186 ns over 1,000, maximum 520 ns"],
        ["Bursts of 16 words", "2.88 ACLK per word = 347 MB/s"],
        ["Data integrity", "1,000 words written, read back and compared: 0 errors"],
    ], [5.0, 12.0], "The DDR probe on the board (gateware 4311)."),
    ("fig", "fig11_vram.png", "Left: the time scales involved (the VDP dot clock and the Z80's cycle against the measured DDR latencies). Right: the block RAM needed for a VRAM, against the 63 blocks that the pool can free at best.", 16.5),
    ("p", "A Z80 memory cycle at 3.58 MHz is about 840 ns, so a 256 ns read started when the address is valid fits inside one cycle, and the rare 1 µs outlier is one wait state (`WAIT_n`). The CPU can use far memory. "
          "A video chip is the opposite. The TMS9918A (and the V9938, and the MC6847) fetch their memory on a fixed schedule of a few dot clocks, one dot being 93 ns at 10.74 MHz, and have no wait input: a late byte is a wrong pixel. "
          "So the rule that came out of the probe, and that every machine since has followed, is **CPU-side memory may wait; video memory may not.**"),
    ("h2", "9.2 Where each memory of the MSX1 lives"),
    ("table", ["Memory", "Size", "Where", "Why"], [
        ["Main RAM (slot 3)", "64 KB", "the pool (block RAM)", "no wait states; shared with the other machines' RAM, so it costs nothing extra"],
        ["**VRAM**", "**16 KB**", "**the pool: eight blocks** (the CP-400's ROM blocks)", "the VDP cannot wait; 16 KB is small"],
        ["BIOS, cartridge, disk ROM", "up to 96 KB", "DDR + 8 KB read cache", "read-only, sequential instruction fetch (the cache hits), the Z80 can wait on a miss"],
        ["Frame buffer", "24 KB", "the pool", "shared with every machine's picture"],
    ], [3.4, 1.8, 4.8, 7.0], "The MSX1's memories."),
    ("h2", "9.3 The MSX2: what went wrong with 128 KB"),
    ("p", "The first MSX was an MSX2 (KdL's OneChip MSX with the V9958), because an MSX2 runs MSX1 software. Its VRAM is 128 KB, and that one memory broke the plan. In the original design everything (RAM, ROMs, VRAM) sits in one SDRAM behind a fixed-timing controller; "
          "the fabric has no SDRAM, only the DDR whose numbers are above. RAM and ROMs could move to DDR with wait states; the VRAM could not. The arithmetic of keeping it on the chip, with block RAMs of 20 Kbit (2K × 10) and 84 on the chip:"),
    ("table", ["Way to keep a 128 KB VRAM", "Blocks", "Verdict"], [
        ["Natural mapping: 16-bit word = two blocks of 8 used bits", "64", "One block more than the pool can free (63 at best): not buildable at ~100 % of the chip."],
        ["**Packed**: five 16-bit words in eight blocks (row = adr[10:0], slot = adr[15:11]); a byte write is a read-modify-write of an 80-bit row", "56",
         "Fits, verified in simulation against a plain model (0 of 1.28 M ticks differ once writing stops). Costs ~2K LUTs of block-RAM interface logic and needs a two-tick write."],
        ["64 KB VRAM only (what the MSX2 standard allows)", "32", "No screens 6 - 8 and many games need 128 KB."],
        ["VRAM in DDR with a small cache", "2 - 3", "Tried as a design (write-through, ~4 KB in 64-byte lines); the VDP stalls on a miss for ~0.45 µs. Estimated ~1 % stall for display scanning but several times slower VDP blitter commands. With it the three-machine design still reached 24.07K LUTs. Abandoned."],
    ], [8.4, 1.6, 7.0], "The MSX2's VRAM options."),
    ("p", "The MSX2 branch built and simulated (C-BIOS logo and text screen, screen 5 and 7 byte ramps bit-exact, the packed VRAM identical to a plain one) at 20.0K LUTs and 76 block RAMs, but together with the CP-400 it needed 24.7K LUTs and 87 block RAMs on a chip with 22,956 and 84. "
          "The choice (2026-11-01) was to drop the MSX2 and build an MSX1 with a ZX Spectrum and an MC-1000 instead: all of them smaller, sharing one Z80, with VRAMs of 16 KB or less."),
    ("h2", "9.4 Is it still true?"),
    ("p", "Yes, in a smaller form. The MSX1's VRAM is 16 KB, **eight pool blocks, on the chip**, for the same reason as before: the VDP's fetch schedule. What changed is that the amount is small enough that the question stopped costing anything: "
          "the blocks are the CP-400's ROM blocks reused, so the VRAM is free. The question will come back for any machine with 64 KB or more of video memory (an MSX2, a Mega Drive, a SAM Coupé): that machine needs either a smaller chip share for its other memories, "
          "a bigger chip, or a cache design whose cost has to be re-estimated with its blitter workload in mind. We have the numbers; we do not have a free 56 blocks."),

    # ------------------------------------------------------------------------------------------------ 10
    ("h1", "10. Disks, tape and sound"),
    ("h2", "10.1 One WD1793, three front ends"),
    ("fig", "fig12_disk.png", "The sector service. Three machines have a floppy controller front end, all on the one WD1793 (a second bus on the CP-300 core); every sector request goes to the daemon, which finds the sector in an image file.", 16.0),
    ("table", ["Front end", "Where", "Sector", "Flow control", "Images"], [
        ["CP-300", "the TRS-80 Model III's controller ports", "up to 512 (DMK)", "the controller's own", "DMK (JV1, JV3, HFE converted by `dsk2dmk.py`), HDV for the WD1010"],
        ["CP-400", "`$FF40-$FF4F` (`bvf_cocofdc`)", "256, `sec512 = 0`", "HALT = halt-enable and not DRQ; INTRQ clears the enable; NMI = INTRQ and density", "CoCo `.DSK`, `.JVC` (35 × 18 × 256 = 161,280 bytes)"],
        ["MSX1", "slot 2, `$7FB8-$7FBC`", "512, `sec512 = 1`", "the ROM polls `$7FBC`: b7 INTRQ, b6 /DRQ", "raw `.DSK` (720 KB, 360 KB, 640 KB, 320 KB)"],
    ], [1.8, 3.8, 2.6, 4.6, 4.2], "The floppy front ends."),
    ("h2", "10.2 The request/response protocol"),
    ("p", "`bvf_fdc` (168 LUTs, 177 flip-flops) turns a controller's sector command into a request the host can read: `REQ` (read sector, write sector, read address; side; drive; track; sector; hard-disk bit), a 512-byte buffer in the sector window "
          "(its shadow RAM is eight uSRAMs, no block RAM) and `ACK` (b0 = the buffer belongs to the host; found, CRC error, deleted-mark bits). `DRIVES` carries the ready and write-protect flags of four floppies and two hard disks and **keeps its value while the core is held**, so the daemon "
          "sets the flags before releasing the machine. The daemon (`diskimg.py`, a Python port of the Pocket firmware's C code plus the HDV, raw and CoCo formats) answers one sector per request: a pending request raises the interrupt, the daemon reads `REQ`, fills or drains the window and writes `ACK`; "
          "the controller waits, so a slow answer slows the disk but never corrupts it. Writes land in the daemon's in-memory copy and are saved to `/var/lib/cp300` every two seconds if the bytes actually changed."),
    ("p", "**Latency.** With one request per sector the interrupt-to-answer time becomes the speed of the disk. The counters in the daemon's statistics (`lat_max_ms`, `lat_slow`, `lat_last_slow`) showed about **35 ms per request**: a CP-300 `DIR` of about 1,700 sectors took over a minute. "
          "The likely cause was Python's thread switching and the picture work competing with the disk service; the fix in the daemon (a 0.5 ms switch interval, the picture limited to 10 frames per second while a disk request has just been answered, a stale interrupt timestamp removed) was tested "
          "against simulated registers and is reported as not yet confirmed on the board at the time of writing."),
    ("h2", "10.3 Building a front end for a ROM you cannot change: the MSX disk interface"),
    ("p", "The MSX1's disk interface is the Gradiente Expert DD Plus's. We have its 16 KB disk ROM but no schematic, so the controller was modelled by disassembling the ROM's own accesses. It worked in simulation immediately and then took **three corrections on real software**, "
          "each found only because the real ROM runs against it:"),
    ("table", ["Symptom on the board", "Cause", "Fix", "How it was found"], [
        ["\"Illegal function call in 0\" instead of Disk BASIC", "the disk ROM had been loaded into slot 0 page 2, so the BIOS ran it as a BASIC program", "a separate slot for the disk ROM (slot 2, page 1), an eject button for the page-2 ROM", "the message itself"],
        ["\"Disk offline\"", "`$7FBC` bits 1:0 select the drive **one-hot** (1 = A, 2 = B); the gateware decoded them as binary", "one-hot decode (gateware 4325)", "disassembling the ROM's writes: the ROM writes `$09` for drive A (motor bit + one-hot drive bit)"],
        ["\"Disk I/O error\"", "bit 6 of the `$7FBC` read is **/DRQ**: the ROM's transfer loop runs while it is 0; the gateware had it active-high", "invert it (4326)", "the transfer loop's `BIT 6,A` / branch, and the simulation's own test program had the same wrong assumption"],
        ["Black screen after the splash, only with the disk interface present", "the ROM copies its sector routine into RAM near `$0000` and runs it with the card selected in **page 2**: it reads `$BFB8`, `$BFBB`, `$BFBC`; the decode answered only in page 1, so the loop polled an empty bus forever", "the registers also answer in page 2; the ROM does not (4327)", "the daemon's Z80 bus sampler showed the CPU looping in low RAM and reading `BFB8`; the ROM's code has `LD BC,BFBC` / `LD (BFB8),A`"],
    ], [3.9, 5.0, 3.8, 4.3], "The MSX disk interface: corrections in the order found."),
    ("p", "After the third correction (package 0.14.4) the MSX1 boots MSX-DOS from the floppy image on the board. *The test program in the simulation had been written from our understanding of the interface, so it passed all three times.* "
          "A bench that models the device from the same belief as the device cannot find a wrong belief; the real driver is the only test that can (L9)."),
    ("h2", "10.4 The CP-400's hard disk: two puzzles"),
    ("p", "The MiniIDE passed its simulation with the real HDB-DOS cartridge, then said \"LBA HARD DRIVE NOT FOUND\" on the board. Two causes, found with a register poller on the board and, for the second, by running the DOS's steps by hand from CP-400 BASIC (`POKE`/`PEEK` of `$FF50-$FF58` is a good bus probe):"),
    ("ul", [
        "**Host latency.** The daemon's single loop was busy with the 24 KB picture when the IDENTIFY request arrived and answered after 166 ms; the DOS gives up after a short wait. *Fix:* the pump serves disk requests only, and the picture, audio and saving moved to a lower-priority path with the XOR and zlib in threads.",
        "**A bit that never shows.** The IDENTIFY request was encoded as `3'b100`. On the board the request kind read as 0: bit 2 never appeared on the bus, although the simulation of the same RTL (also over the register bus) shows 4 and the synthesised netlist has the flop. "
        "The cause was not found. *Work-around:* encode IDENTIFY as 3 (read and write: no command is both) so the next gateware does not use bit 2, and let the daemon treat kinds 0, 3 and 4 as IDENTIFY.",
        "**Word order of the data port.** The DOS found the drive but the file names were scrambled. The simulation, run with the DOS on the user's real sectors, printed exactly the screen of the board, so *the simulation was the oracle*: iterating in simulation (no board) found the rule (the DOS stores a pair [$FF50 of iteration j+1, $FF58 of iteration j]) and the window order that inverts it. "
        "The user's 507 MB OS-9 image then booted. Sector writes are still refused: the last byte pair cannot be recovered from the lagging low bytes.",
    ]),
    ("h2", "10.5 Tape and sound"),
    ("fig", "fig14_events.png", "Sound goes from the fabric to the host as timestamped edges; the cassette recorder (all machines) is fed by the host and gated by the machine's motor line.", 16.0),
    ("p", "**Sound** (decision D6): `bvf_audio` compares the machine's speaker value (0 to 511) with the previous one every clock and pushes `{level[8:0], time[22:0]}`; time is a free-running microsecond counter (wraps at 8.39 s). A 256-entry FIFO sits between fabric and host; on overflow new edges are dropped and a sticky `lost` flag is set. "
          "The browser converts timestamp differences to sample counts and schedules them about 60 ms ahead of the audio clock, so latency is a constant, not a distortion."),
    ("p", "**Tape** (`bvf_tape`, shared by all machines): the host pushes pulse durations (microseconds, with a hold bit for pauses over 2²⁰ µs) into a 1,024-entry FIFO; the input level toggles at the end of each entry; "
          "time runs only while PLAY is on and the machine's motor is on (or FORCE), like a recorder whose motor the computer switches. The record side stores every change of the machine's output as `{level, microseconds since the previous change}` in a 512-entry FIFO. "
          "Per machine the connection is: CP-300 port `$FF`; CP-400 PIA1 PA0 / the DAC's top bit / CA2 motor; MSX1 PSG register 14 bit 7 / PPI C bits 5 and 4; ZX port `$FE` bits 6 and 3; MC-1000 PSG ports B7 / A7; the Alice inside the emulator (the same entries over its stdin). "
          "Formats: `.tap`, MSX `.cas` (1200 baud), CoCo/MC-10 `.cas` / `.c10` (1200/2400 Hz), TRS-80 `.cas` (500 baud), `.wav`; recording gives a `.wav`. Simulated; the header lengths and polarities the ROMs expect are from the formats' documents and have not been tried with real programs on a board."),

    # ------------------------------------------------------------------------------------------------ 11
    ("h1", "11. The picture path"),
    ("fig", "fig13_frames.png", "Every machine's picture goes through `bvf_fb`, in one of two modes, and the host reads it in bulk.", 16.0),
    ("h2", "11.1 Capture"),
    ("p", "The machines already produce a pixel stream with a pixel enable, blanking signals and a pixel value. `bvf_fb` counts x and y, shifts pixels into 32-bit words and writes them to RAM. Two modes:"),
    ("ul", [
        "**CP-300 (m4 = 0):** 512 × 192 × 1 bit = 12,288 bytes = 3,072 words, `word = y × 16 + x / 32`, pixel x in bit (x mod 32), leftmost pixel least significant, so a little-endian host sees LSB-first bytes in reading order and never shuffles bits. Two buffers; the writer publishes (`latest`, a 16-bit counter) when a frame ends and flips.",
        "**Everything else (m4 = 1, \"direct\"):** 256 × 192 × 4 bit colour index (0 to 15; the page owns the palette) = 24,576 bytes, one buffer. The host sets HOLD (`CTRL` b6), waits for `STATUS` b6 (no frame is being written), reads the words and clears HOLD; a new frame is not started while HOLD is set.",
    ]),
    ("h2", "11.2 Tear-free reads"),
    ("p", "The CP-300's capture must never wait for Linux, so it is lock-free: the host reads the counter, bulk-reads the newest buffer, reads the counter again, and accepts the copy only if the counter advanced by less than two. A copy taken while the writer lapped the reader is discarded and retried (the daemon counts "
          "`stats.dropped`). The generalisation holds for any rate-limited stream the host samples: *double buffer plus a monotonic counter read before and after.* The colour machines can afford HOLD because their picture is regenerated every frame from machine state that is stable while the picture is skipped."),
    ("h2", "11.3 To the browser"),
    ("p", "Each client receives the XOR of the current frame with its own previous frame, compressed with zlib level 1; most pixels do not change, so a frame becomes a few hundred bytes. A new client gets a whole frame (kind 0). The page applies an XOR frame only if it has the previous frame and the sequence number follows; "
          "otherwise it drops its copy and asks for a key frame, which makes the daemon clear that client's previous frame. The page expands the bytes to RGBA, draws them with `putImageData` and scales the canvas by CSS to a **4:3** box with `image-rendering: pixelated`: the real tube displays 512 × 192 on a 4:3 screen, "
          "so each dot is twice as wide and four times as tall. *The fidelity of a retro display is a property of its geometry, not of the framebuffer.*"),
    ("p", "**A one-pixel trap.** The MSX1's picture was clipped by one pixel at the left edge: `bvf_fb` takes the colour one clock after the pixel enable but the blanking from the enable edge itself, so the VDP's colour needed one more clock of delay (`col_q` in `bvf_msx1.v`). A testbench of the capture alone (`tb_vdp18win`) now guards it."),
    ("p", "**Speed.** Measured in the page: the CP-300 about 38 - 40 frames per second against a 60 Hz source, the CP-400 about 12 (package 0.6.0, before the disk-latency work). The bus is never the bottleneck (a bulk read is 1.5 ms for 12 KB); the Python XOR over the frame and the WebSocket framing are. "
          "Moving the XOR into the helper library, or into the fabric, would remove it."),
]
