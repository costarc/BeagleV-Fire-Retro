BLOCKS = [
    # ------------------------------------------------------------------------------------------------ 4
    ("h1", "4. Key decisions and the reasons"),
    ("p", "Each entry: what we chose, what we rejected, why. D1 to D10 are the decisions of the first port and still hold; D11 to D15 came with the other machines."),

    ("h3", "D1. Wrap the cores; keep the shared RTL almost untouched"),
    ("p", "The CP-300 core, the WD1793 and WD1010 controllers and the T80 are used as they are on the other ports. The BeagleV-Fire adds glue in `rtl/`. "
          "Three small, deliberate changes were needed in the shared core: the Z80 can be external (`EXT_CPU`, so that one T80 can serve several machines), "
          "the WD1793 has a second bus for the other machines' floppy cards, and a `sec512` input (512-byte sectors for the MSX). The CP-300 core files are "
          "vendored in `cp300core/` in this repository. **Cost:** no BeagleV-specific optimisation inside the core."),
    ("h3", "D2. The browser is the whole front end"),
    ("p", "*Rejected:* a bare-metal framebuffer driver (no connector to drive); a local Qt/SDL application (needs a display on the board); a VNC wrapper (a second "
          "protocol stack, poor audio). *Chosen:* a web page. The board already runs a web server and is reached over a network; browsers give a canvas, keyboard "
          "events, WebAudio, file drag and drop and a 4:3 layout engine for free, on any client OS, including a phone."),
    ("h3", "D3. One memory-mapped window, no kernel driver"),
    ("p", "*Rejected:* a custom kernel module (fragile against the board's exact kernel); a network path to the fabric; DMA descriptors. *Chosen:* a **generic UIO device**: "
          "the device-tree overlay declares a 1 MB region with `compatible = \"generic-uio\"`, the kernel exposes it as `/dev/uio0`, and an ordinary process maps it. "
          "UIO ships in the stock kernel. **Cost:** programmed I/O; a full frame is still read in about 1.5 ms."),
    ("h3", "D4. An interrupt wakes the host for disk requests; a timer drives the rest"),
    ("p", "The fabric raises a level interrupt for a pending sector (or FreHD, IDE) request. It is wired to bit 0 of the cape's `INT[23:0]` bus (`MSS_INT_F2M[8]`), which the "
          "overlay declares as PLIC source 126. The daemon unmasks it only after answering, so with a level interrupt nothing is missed. A timed wake-up (0.5 ms after disk "
          "work, 4 ms idle) stays for picture and audio, and as the fallback on gateware without the interrupt."),
    ("h3", "D5. Frames are pulled and validated, not locked"),
    ("p", "The machine's timing must never depend on Linux. The CP-300's capture double-buffers and publishes a frame counter; the host brackets its bulk read with two counter "
          "reads and discards the copy if the writer lapped it. The other machines use a single buffer with a host-set HOLD bit (section 11)."),
    ("h3", "D6. Audio is sent as edges with microsecond timestamps"),
    ("p", "Retro sound is one bit toggled by software. Sampling it quantises the timing and wastes bandwidth when silent. The fabric pushes `{level, time}` on every change; the "
          "browser rebuilds the waveform at its own sample rate. Silence costs nothing, timing is exact to 1 µs, and host latency only delays the sound without distorting it."),
    ("h3", "D7. The host is the disk; the fabric is the client"),
    ("p", "When the emulated CPU reads a sector, the floppy controller asks the host through REQ/ACK registers; Linux answers from an image file. All file handling "
          "(formats, persistence, download) is Python, testable without hardware. Since V2 this is one sector per request; since V3 three different controller front ends share it (section 10)."),
    ("h3", "D8. The window is a 32-bit bus with no byte strobes"),
    ("p", "Discovered the hard way (L1). All access goes through a ten-line C helper that issues real `lw`/`sw`; no layer above it assumes a byte store works."),
    ("h3", "D9. One bridge from a 50 MHz bus to a 42 MHz core, with a toggle handshake"),
    ("p", "A four-state toggle handshake moves exactly one register access at a time between the domains; one mechanism covers every register and every RAM window."),
    ("h3", "D10. Ship a package with an installer, not a build recipe"),
    ("p", "The gateware needs Libero SoC 2026.1 (unofficial for this framework) and a pinned bootloader; no end user should repeat that. The package holds the bitstream, the overlay, the daemon, the page, the service "
          "and an installer that is idempotent and asks for explicit acceptance before it touches the flash (section 13)."),
    ("h3", "D11. One Z80 for every Z80 machine"),
    ("p", "A T80s costs 2.3 to 2.6K LUTs. Four copies (CP-300, MSX1, ZX, MC-1000) would be about 10K LUTs for hardware of which only one is ever awake. The CPU is one block; its address, "
          "data and control buses and its clock enable are multiplexed to the selected machine (section 7.1). *Cost:* every machine must fit the T80's bus-cycle shape (writes complete when /WR ends; "
          "the interrupt-acknowledge cycle must read `$FF`); machine-specific timing is expressed through the clock enable."),
    ("h3", "D12. One block-RAM pool for every machine"),
    ("p", "The 64 KB RAM, the frame buffers, the CP-400's ROMs and the cartridge ROM are blocks of one array (`bvf_pool`), assigned per machine (section 7.2). The MSX1's VRAM is the CP-400's ROM blocks "
          "reused. *Cost:* the mux logic (a pool is not free: block-RAM interface logic is about 36 LUTs per block) and the rule that nothing may use a block while another machine runs."),
    ("h3", "D13. RAM and VRAM on the chip; ROMs in DDR behind a cache; CPU-side waits only"),
    ("p", "The DDR probe gave 256 ns typical and 1.09 µs worst-case reads. A Z80 memory cycle at 3.58 MHz is 840 ns, so a read fits in one cycle and the rare slow one is a WAIT. A video chip fetching "
          "every few dot clocks (93 ns) cannot wait. So: RAM 64 KB (no wait) and VRAM on the chip; the MSX1's ROMs (up to 96 KB) in DDR with an 8 KB read cache. Details in section 9."),
    ("h3", "D14. A CPU that is slow and simple belongs on the host"),
    ("p", "The Alice's MC6803 needs 0.2 to 0.3 million instructions per second. A fabric core would need logic the chip does not have; the host has cycles to spare. Section 8."),
    ("h3", "D15. Reset and power are different things"),
    ("p", "A real RESET keeps the RAM (the CoCo's ROM even looks for a warm-start flag; a game survives it). Only switching off clears it. The register `CTRL` has a RESET pulse and a COLD pulse; "
          "COLD starts `bvf_ramclr`, which writes zero to all 65,536 bytes (1.6 ms at 42 MHz) with every machine held, and then the machine starts from nothing. The page has Reset and Power buttons accordingly."),

    # ------------------------------------------------------------------------------------------------ 5
    ("h1", "5. The platform: what the BeagleV-Fire gives you"),
    ("p", "The integration points transfer to other SoC-FPGA boards (Zynq, Cyclone V SoC, Agilex, other PolarFire SoC boards); the device details do not."),
    ("ul", [
        "**The MSS** (microprocessor subsystem) holds the RISC-V cores, the memory controller and the buses; its configuration is *generated* (`pfsoc_mss`) and is not part of the fabric design.",
        "**The FIC** exposes the fabric as address ranges in the processor's physical map and carries fabric interrupts back. In the board's framework the fabric bus is `fabric-bus@40000000` "
        "in the device tree, and a \"cape\" receives an **APB3 slave** at `0x41000000` (16 MB of window; this project uses the first 1 MB) and 24 interrupt lines. A second port, **FIC0's "
        "AXI4 initiator**, reaches DDR: 64-bit data, 125 MHz.",
        "**The gateware framework** (BeagleBoard.org) is a Libero Tcl build system that assembles the MSS, the stock infrastructure and a selectable cape option. Adding a design means adding "
        "a cape directory; `gateware/make_cape.py` does this.",
        "**Boot and flashing.** The bootloader (HSS) and the bitstream live in SPI flash. Reprogramming the fabric rewrites that flash through `change-gateware.sh`, **with no fallback copy**. "
        "This single fact shaped the installer and the disclaimer more than anything else.",
    ]),
    ("note", "**Transferable rule.** On any SoC-FPGA find out first (1) how the CPU addresses fabric registers and how wide and strobe-capable that path is, (2) how the fabric's identity "
            "reaches the OS, (3) what happens when the fabric is reprogrammed under a running Linux, and (4) how you get back if you break the boot path."),

    # ------------------------------------------------------------------------------------------------ 6
    ("h1", "6. The FPGA/CPU interface"),
    ("h2", "6.1 The address map"),
    ("table", ["Offset", "Window", "Use"], [
        ["`0x00000`", "registers", "ID `0x43503005`, CTRL, STATUS, keys, FRAME, AUDIO, REQ/ACK/DRIVES, IDE, DDR probe, FreHD, ALICE, tape, DEBUG (appendix A)"],
        ["`0x10000`", "ROM load (write only)", "word n of a ROM image at `0x10000 + 4n`, first byte in bits 31:24 (the CP-300's system ROM and character generator, the ZX ROM, the CP-400's ROMs, the MC-1000 ROM, the Alice ROM goes to the emulator)"],
        ["`0x20000`", "sector buffer (512 B)", "the floppy / hard-disk controllers' sector in transit, little-endian words"],
        ["`0x30000`", "frame RAM (read only)", "buffer 0 at `0x30000`, buffer 1 at `0x34000` (CP-300); one 24 KB buffer for the colour machines"],
        ["`0x40000`", "IDE sector buffer", "the CP-400's MiniIDE sector, 512 bytes"],
        ["`0x50000`", "FreHD data buffer", "word n = byte n, 256 words"],
        ["`0x60000`", "Alice VRAM (write only)", "word n = VRAM bytes 4n..4n+3, n = 0..1535"],
    ], [2.2, 3.4, 11.4], "The register window. Unmapped windows read as zero."),
    ("p", "**Design rule used throughout:** *one register file is the only interface; the other windows are bulk memories hanging off the same address decoder.* A new peripheral costs one more "
          "`case` arm and one more window, never a new bus. The `ID` register is the contract's version: it has had five values (`...01` IO controller mailbox, `...02` one machine and no IO controller, "
          "`...03` machine select and frame hold, `...04` the Alice, `...05` tape), and the daemon refuses to run against a gateware with a different one."),
    ("h2", "6.2 Crossing from the 50 MHz bus to the 42 MHz core"),
    ("p", "The APB3 slave runs on PCLK; the machines run on a PLL-derived 42 MHz clock. Rather than synchronise every signal the bridge synchronises a single bit:"),
    ("code", """PCLK domain                                   core clock domain
-----------                                   -----------------
psel & penable & !busy -> latch addr/wdata/wr
                       -> req_tog flips   --2FF-->  rq2 != rq3 ?  -> drive the register bus for 1 clock
busy = 1                                            read: wait 2 clocks for data (registered RAM outputs)
ack2 == req_tog  <--2FF--  ack_tog flips  <-------- done
-> prdata = r_rdata, pready = 1 (1 clock), busy = 0"""),
    ("ul", [
        "**One flag in flight per direction**, so single-bit toggles through a two-flop synchroniser are safe. The *data* is not synchronised: it is stable for the whole handshake by construction.",
        "**PREADY is used.** APB3 permits wait states, so a 12 KB frame is read with ordinary loads and the CPU simply waits. The framework's template cape exposes only `PRDATA`; `make_cape.py` adds `PREADY` and `PSLVERR` to the cape's ports.",
        "**The cost** is several clocks of each domain per access: irrelevant for control and mailbox traffic, and for the frame it defines the 1.5 ms bulk read.",
        "**A known gap:** there is no bus timeout. If the 42 MHz clock were absent the CPU would hang on the access.",
    ]),
    ("h2", "6.3 Control, the start sequence and the three hold states"),
    ("p", "`CTRL.run = 0` holds every machine in reset. The daemon's power-on sequence is the contract the registers were designed around:"),
    ("code", """1. CTRL.run = 0                        # hold everything (machine select changes only here)
2. load the machine's ROMs             # ROM window (word packing) or, for the MSX1, the DDR window
3. publish DRIVES, IDE_CFG             # drive ready / write-protect flags; kept while run = 0
4. CTRL.run = 1 with COLD              # RAM cleared (1.6 ms), then the machine starts from nothing"""),
    ("p", "Step 3 is before step 4 because the drive flags are read by the machine at its first access; the first port got this order wrong (L2). The hold conditions are nested and keeping them "
          "straight is most of the debugging:"),
    ("code", """core_reset (CP-300) = ~run | ~pll_locked | rst_pulse | clr_active | ~m300     # one such term per machine
regs reset         = ~pll_locked                                           # so that run can be written
audio / tape reset = ~run
frame capture      = no reset: it captures whatever the machine's video produces"""),
    ("h2", "6.4 The read-latency convention"),
    ("p", "`bvf_regs` documents one convention that every block follows: **read data is valid two clocks after the read strobe**. RAM outputs are registered (one clock) and the window mux is selected "
          "by a delayed copy of the address, so the mux picks the window of the previous request. Fixing this once, in a comment at the top of the register file, saved reasoning per block about when data appears."),

    # ------------------------------------------------------------------------------------------------ 7
    ("h1", "7. The machines"),
    ("p", "Each machine is a small design around a core that already existed; the sections below describe how each one is attached to the shared infrastructure and what had to change. "
          "Sources and licences are listed in appendix C."),
    ("h2", "7.1 One Z80 for four machines"),
    ("fig", "fig04_shared_z80.png", "The shared Z80. The T80s is a single instance; its buses, interrupt, reset and clock enable are multiplexed to the selected machine. The CP-400 has its "
                                    "own 6809 and the Alice has no CPU in the fabric.", 15.5),
    ("p", "The CP-300's core (derived from the HT1080Z) was written with its Z80 inside; a generic (`EXT_CPU`) moves the CPU outside as `ht1080z_bvf.vhd`. Each machine then supplies a clock enable and receives the CPU's bus:"),
    ("table", ["Machine", "Effective Z80 clock", "What the machine adds"], [
        ["CP-300", "its own enable (the HT1080Z's)", "video, keyboard, WD1793/WD1010, FreHD interface, speaker"],
        ["MSX1", "3.58 MHz = `ena21` / 6, with `ena21` = 45/88 of 42 MHz (21.477 MHz)", "slot logic and PPI, TMS9918A on `ena21` / 2, PSG, WAIT when a ROM byte is not in the cache"],
        ["ZX Spectrum", "3.5 MHz = 42 MHz / 12", "own ULA; no contention, no floating bus"],
        ["MC-1000", "3.58 MHz", "MC6847 VDG, PSG, keyboard through the PSG's ports"],
    ], [2.6, 5.4, 9.0], "Clocking of the machines on the shared Z80."),
    ("p", "Two bus-cycle rules of the T80s caused real bugs and are worth stating. **A write is acted on when /WR ends**, with the address and data captured while it is low (the T80 puts them out after /WR falls). "
          "**During the interrupt-acknowledge cycle (M1 with IORQ) the bus must read $FF and memory must not answer**, or the vector the CPU takes is wrong."),

    ("h2", "7.2 One block-RAM pool"),
    ("fig", "fig05_pool.png", "`bvf_pool`: 56 of the chip's 84 block RAMs, assigned differently by each machine.", 15.5),
    ("p", "The 64 KB RAM has one read address and one write address (separate ports), with one clock of read latency; whoever owns the address mux owns the memory. The frame buffer is three sets of four blocks. "
          "The CP-400's two 8 KB ROMs are eight blocks that every other machine reuses: as the MSX1's 16 KB VRAM, the MC-1000's 8 KB VRAM and the Alice's 6 KB VRAM. The cartridge blocks are the CP-400's DOS cartridge "
          "and the MSX1's ROM read cache. A power-on clear (`bvf_ramclr`) writes zero to the whole 64 KB while the machines are held; it skips the ZX Spectrum's ROM (the lower 16 KB) and the MC-1000's ROM (the upper 16 KB), "
          "which live in the same array."),

    ("h2", "7.3 CP-300 (machine 0)"),
    ("p", "A Z80 machine with a 512 × 192 monochrome display, a 64-position keyboard matrix, a one-bit (three-level) speaker, a WD1793 floppy controller and a WD1010 hard-disk controller. The system ROM (16 KB) "
          "and the 2 KB character generator are loaded by the daemon (they are copyrighted: never part of a bitstream or a package). The FreHD hard-disk interface (`bvf_frehd`, ports C2 to C5) sits on the core's "
          "expansion bus and presents the board's PIC firmware's command set over a folder on the SD card (`frehd.py`): open, read, seek, directory, mount an `.hdv`. The core's own cassette port is bridged to the shared tape unit."),

    ("h2", "7.4 CP-400 / CoCo 2 (machine 1): a 6809 machine"),
    ("fig", "fig06_cp400.png", "The CP-400: its own CPU (`cpu09`, a John Kent 6809), the SAM, the MC6847 and two PIAs, on the shared RAM, frame capture, tape, floppy controller and IDE.", 16.0),
    ("p", "The CP-400 is the user's own CoCo 2 core (Victor Trucco's Multicore core, based on Mark McDougall's PACE), reduced to its board-independent part (`cp400_core.vhd`) and re-clocked. The original runs at 57.27 MHz with a 14.318 MHz enable; "
          "here the 42 MHz core clock with an enable of **exactly 15/44** of it, so the machine has real NTSC speed. Two details cost a debugging day each: the CPU enable must be combinational at the first clock of E "
          "(a registered enable was two clocks late and corrupted every 15th RAM write), and the cartridge line must be held high when no cartridge is present (with the original's `CART = Q` the ROM took FIRQs and restarted forever)."),
    ("p", "Storage and the rest: a **MiniIDE** (`bvf_ide`, ATA PIO, LBA28, 461 LUTs) replaces the original's OCIDE and SD card at `$FF50-$FF5F`; the daemon serves its sectors; an HDB-DOS cartridge ROM is optional. "
          "A **floppy controller card** (`bvf_cocofdc`, `$FF40-$FF4F`) puts the CP-300's WD1793 on the CP-400's bus with the CoCo's control register, HALT on DRQ and NMI on INTRQ (section 10). Tape goes through PIA1 PA0 / the DAC / CA2. Joysticks are centred; "
          "serial is not implemented."),

    ("h2", "7.5 MSX1 (machine 2)"),
    ("fig", "fig07_msx1.png", "The MSX1. RAM and VRAM are on the chip; the ROMs (and the disk interface ROM) are in DDR behind an 8 KB read cache.", 16.0),
    ("p", "The MSX1 is built from the TMS9918A (vdp18 by Arnim Laeuger, from the MSX1fpga core) and the PSG of KdL's OCM-PLD, with the slot logic written here. The slot map: slot 0 the 32 KB BIOS + BASIC (and a 16 KB ROM in page 2 for C-BIOS's logo); "
          "slot 1 a cartridge of up to 32 KB at `$4000-$BFFF`; slot 2 the disk interface (below); slot 3 the 64 KB RAM, which is the pool's (no wait state). Keyboard: the page sends an 88-bit matrix (`KEYS_LO/HI` and `KEYS2`). "
          "The tape input is PSG register 14 bit 7; the motor and output are on PPI port C."),
    ("p", "**ROMs in DDR.** The BIOS, cartridge and disk ROMs sit in the reserved 32 MB region at `$C800_0000`, loaded by the host while the machine is held (through the same AXI master the probe uses; while `CTRL.run = 0` the probe owns the bus). "
          "In front of them an 8 KB read cache (1024 lines of 8 bytes, direct-mapped, in the pool's cartridge blocks): a hit answers without a wait state; a miss asserts WAIT on the Z80 until one 64-bit DDR word is in. "
          "The tags are cleared after every reset. This is decision D13 at work: the Z80 can wait, so ROMs can be far away."),
    ("p", "**The video memory is not in DDR.** The VDP fetches VRAM every few dot clocks (a dot is 93 ns at 10.74 MHz) and cannot wait; its 16 KB are eight pool blocks (section 9)."),
    ("p", "**The disk interface.** The Gradiente Expert DD Plus's layout (\"National\" style) was decoded from the disk ROM's own accesses: WD1793 registers at `$7FB8-$7FBB` and a control/status register at `$7FBC`. "
          "The first implementation worked in simulation and then needed three corrections on real software (section 10 and L9)."),

    ("h2", "7.6 ZX Spectrum 48K (machine 3)"),
    ("fig", "fig08_zx.png", "The Spectrum's ULA reads the screen through the same single read port as the CPU. Twelve core clocks make one T-state; the ULA owns the port for two of them.", 16.0),
    ("p", "There was no ZX core we could use on the shared Z80, so the ULA is written here (`bvf_zx`). The Z80 runs at 3.5 MHz (one T-state is 12 clocks of the 42 MHz clock, a pixel is six). Memory is the pool's 64 KB with the ROM in its lower 16 KB, written by the host "
          "while the machine is held and write-protected afterwards. The pool has **one read port**: in every T-state the CPU's address is on it, except at clocks 2 and 3 of the second T-state of a character cell, where the ULA reads the bitmap byte and the attribute byte of the *next* cell. "
          "The Z80 takes its data at clock 11, so it never sees the ULA's bytes. The picture is 448 × 312 pixels at 50.08 Hz; only the 256 × 192 window is captured, the border colour is an output of its own that is not shown. "
          "The interrupt is raised for the first 32 T-states of line 0. There is no memory contention and no floating bus: software that depends on either will differ from a real Spectrum. Keyboard half-rows, EAR (port `$FE` bit 6) and MIC (bit 3) are connected."),
    ("note", "**Open issue.** On two of the four most recent gateware builds (4326 and 4327) the Spectrum boots and runs its ROM but the picture is all black, while on 4325 and 4328 it is correct. The ZX logic is identical in all four, and the simulation of the same RTL shows the picture. "
             "With the debug word of 4327 the ULA's last attribute and bitmap fetches read `00` in all 32 samples while the Z80 sat in the ROM's keyboard loop. The cause is not found; it behaves like a placement-dependent hardware difference "
             "on the one-read-port arrangement. See L10."),

    ("h2", "7.7 MC-1000 (machine 4)"),
    ("p", "The CCE MC-1000 (Brazil, 1985) follows Victor Trucco's MC1000 core without the 80-column card: the shared Z80 at 3.58 MHz, the MC6847 of his core (renamed and given capture ports), the OCM's PSG, the 64 KB RAM at `$0000-$BFFF` and the 16 KB ROM at `$C000-$FFFF` "
          "(loaded by the host; after a reset it is read at every address until the first access to `$C000`). The 8 KB VRAM is the pool's VRAM port, at `$8000-$9FFF` while port `$80` bit 0 is 0; an access to it waits while the VDG shows the picture. "
          "The keyboard is read through the PSG's ports A and B, and the interrupt is an 8.8 µs pulse every 3.45 ms."),

    ("h2", "7.8 Matra Alice / Tandy MC-10 (machine 5): the CPU on the host"),
    ("fig", "fig09_alice.png", "The MC-1000 and the Alice share the MC6847 VDG. For the Alice the CPU, RAM, ROM and keyboard are a C process on Linux; the fabric keeps the video, the VRAM and the sound edge path.", 16.0),
    ("p", "The Alice is a French clone of the MC-10 (1983) with a Motorola MC6803 and an MC6847. Its CPU is emulated in C (`alice/emu`, 93 hand-checked tests, runs the MC-10 ROM to the BASIC prompt); the fabric is the MC-1000's VDG with the Alice's per-byte attributes "
          "(`bvf_mc1000` with `alice = 1`), the pool's VRAM, the register `0xA0` (the `$BFFF` latch: mode, colour set, DAC bit) and the `0x60000` window. About 60 LUTs and no block RAM. Why this and not a CPU core in the fabric is the subject of the next section."),
]
