BLOCKS = [
    ("title", "Retro Computers on the BeagleV-Fire",
     "Six machines in one FPGA bitstream, and a web page as the whole front end",
     "Technical paper, state of 2 November 2026. Project: BeagleV-Fire-Retro (github.com/costarc/BeagleV-Fire-Retro). "
     "Gateware 4328, package 0.14.5."),

    ("h3", "Abstract"),
    ("p", "The BeagleV-Fire is a Linux board built around a Microchip PolarFire SoC: four 64-bit RISC-V application cores and about 23K "
          "logic elements of FPGA fabric on one chip. It has no video connector for the fabric, no keyboard port, no audio output and no "
          "storage the fabric can reach. We run six 1980s computers in that fabric anyway: the Prológica CP-300 (a Brazilian TRS-80 "
          "Model III compatible), the CP-400 (a TRS-80 Color Computer 2 compatible), an MSX1, a ZX Spectrum 48K, the CCE MC-1000 and, "
          "with a processor that is not in the fabric at all, the Matra Alice (a Tandy MC-10 clone). One bitstream holds all of them; "
          "the Linux side selects the machine by writing one register, with no reflash and no reboot."),
    ("p", "Everything a user touches (screen, keyboard, speaker, floppy drives, cassette recorder, hard disk) is provided by **a web page**, "
          "served by a small Python daemon on the board's Linux, which talks to the fabric through **one 1 MB memory-mapped register window**."),
    ("p", "This paper documents the design and, above all, *why* each decision went the way it did. It is organised around the "
          "**architecture variants** we had to design: one CPU shared by four machines, one block-RAM pool shared by all of them, "
          "ROMs in DDR behind a cache, a 6809 machine with its own CPU, and a machine whose CPU runs on the host. It explains in detail "
          "why the Alice uses a soft CPU instead of an FPGA core, why the MSX video memory has to be on the chip (and what the abandoned "
          "MSX2 taught us about it), how three different floppy controllers share one WD1793 and one host-side sector service, and what "
          "went wrong on the way. The retro computers are the example; the subject is the interface problem that appears whenever a "
          "hardware block sits next to a general-purpose CPU: moving a video stream, event streams, bulk storage and control state across "
          "the processor/fabric boundary reliably, cheaply, and in a way a non-specialist can use from a browser."),
    ("toc",),
    ("pagebreak",),

    # ------------------------------------------------------------------------------------------------ 1
    ("h1", "1. The problem and the constraints"),
    ("h2", "1.1 The board"),
    ("p", "The BeagleV-Fire carries a PolarFire SoC MPFS025T: a RISC-V multicore complex (one E51 monitor core and four U54 application "
          "cores running Linux) and an FPGA fabric of 22,956 four-input LUTs and 84 large block RAMs (LSRAM, 20 Kbit each). The only "
          "things the board gives the fabric are a clock, some DDR through the processor subsystem, and **the processor/fabric boundary itself**: "
          "memory-mapped windows in the RISC-V address map (the FIC) and interrupt lines back."),
    ("table", ["Wanted by a retro computer", "Provided by the BeagleV-Fire"], [
        ["A display", "Nothing. No video connector is wired to the fabric."],
        ["A keyboard, joysticks", "Nothing wired to the fabric. USB belongs to Linux."],
        ["A speaker", "Nothing wired to the fabric."],
        ["Floppy drives, tape, hard disk, SD card", "Nothing the fabric can reach. Storage belongs to Linux."],
        ["RAM and ROM", "Block RAM on the chip (small) and DDR through an AXI port (large, variable latency)."],
        ["A clock", "50 MHz bus clock (PCLK), PLLs available; the machines run on a 42 MHz derived clock."],
        ["A way to talk to software", "The fabric interconnect (FIC): a memory-mapped window and 24 interrupt lines."],
    ], [4, 8], "What a retro computer needs and what the board offers."),
    ("p", "So the only thing the board offers is the boundary itself, and everything else has to be built on top of it. That observation is "
          "the whole design: **if Linux can see the fabric as memory, Linux can be the monitor, the keyboard, the speaker and the disk drive**, and "
          "a web server is already running on it."),

    ("h2", "1.2 Requirements we set ourselves"),
    ("ol", [
        "A machine is a wrapper around an existing open core where one exists; we write a machine from scratch only when no usable core exists (the ZX Spectrum's ULA).",
        "Zero special software on the user's computer. A browser is the only client.",
        "A user installs it without a toolchain: a package with an installer.",
        "It coexists with the board's stock software (its web server, Cockpit) and with other gateware designs.",
        "Correctness before speed: 50 Hz video would be nice, a corrupted disk is not acceptable.",
        "Switching machines is instant: no reflash, no reboot, no second bitstream.",
    ]),

    ("h2", "1.3 Where this started"),
    ("p", "The project began as a port of one machine, the CP-300, whose FPGA core already existed for other boards (a DE0, the Analogue Pocket, "
          "MiSTer, Tang Nano). That port used about 78 % of the LUTs and 88 % of the block RAMs and ran the core unchanged, including the helper "
          "processor and firmware that serve disk images on the other boards. Everything in this paper that is not in that first port came from one "
          "ambition: use the same host interface for more machines. The ambition ran into the size of the chip quickly, and most of the "
          "interesting design work is the result of that collision (section 3)."),

    # ------------------------------------------------------------------------------------------------ 2
    ("h1", "2. Architecture overview"),
    ("fig", "fig01_system.png", "The whole system. The user-facing parts are on the left, the machines on the right; red arrows are the two paths that "
                                "do not follow the usual request/response pattern (the interrupt, and the Alice's host-side CPU).", 16.5),
    ("p", "Six machines share one fabric design. Only one runs at a time; the register `CTRL` (bits 9:8 and 5:4) selects it, and the daemon changes it "
          "only while the core is held in reset. Four independent *flows* cross the boundary, and each got the mechanism that suits its nature:"),
    ("table", ["Flow", "Direction", "Nature", "Mechanism"], [
        ["Control (power, reset, turbo, machine)", "host → fabric", "rare, state", "registers"],
        ["Keyboard", "host → fabric", "level state, 64 + 24 bits", "registers, written whole"],
        ["ROM load", "host → fabric", "one-shot bulk write", "write-only window (word-addressed), or the DDR window for the MSX1"],
        ["**Screen**", "fabric → host", "continuous stream, 12 or 24 KB per frame", "frame RAM, read in bulk; consistency by counter (CP-300) or HOLD (others)"],
        ["**Audio**", "fabric → host", "sparse, timing-critical events", "timestamped edge FIFO, popped"],
        ["**Disk**", "fabric → host → fabric", "request/response, *the fabric is the client*", "REQ/ACK registers + 512-byte sector window + interrupt"],
        ["**Tape**", "both ways", "pulse streams", "play FIFO (host-fed) and record FIFO (timestamped edges)"],
        ["Alice's CPU", "host ↔ fabric", "VRAM words and one latch out, key matrix in", "window `0x60000`, register `0xA0`"],
    ], [3.6, 2.2, 3.4, 6.4], "The flows across the processor/fabric boundary and the mechanism for each."),
    ("fig", "fig02_fabric.png", "Inside the fabric. The bus runs at 50 MHz, everything behind the bridge at 42 MHz. One Z80 and one pool of block RAM serve "
                                "several machines; the shared services (frame capture, audio, tape, sector service, DDR) are common to all.", 16.5),
    ("p", "The rest of the paper justifies this picture. Section 3 tells how it came about, section 4 lists the decisions, sections 5 to 7 describe the "
          "interface and the machines, sections 8 and 9 answer the two questions that shaped the design most (the Alice's CPU and the MSX video memory), "
          "and the later sections cover storage, picture, host software, delivery, measurements and lessons."),

    # ------------------------------------------------------------------------------------------------ 3
    ("h1", "3. Architecture variants: what we built and what we threw away"),
    ("p", "The final design is not the first one, nor the best one in the abstract; it is the one that survived contact with a 23K-LUT chip. "
          "This section is the history of the variants, in the order we built them, with the reason each was replaced. The numbers are those recorded "
          "when each gateware was built (early rows are before place and route; they are indicative, not comparable to the last decimal)."),
    ("fig", "fig03_luts.png", "Logic use of the gateware generations. Green bars are the shared-Z80 line that became the final design; the red bars are the "
                              "MSX2 branch that did not fit.", 16.0),
    ("table", ["Variant", "What it was", "Result and the reason it changed"], [
        ["**V1** CP-300 + IO controller (0.2 - 0.3)",
         "The Analogue Pocket core unchanged, with its helper Z80 ('IO controller') and 16 KB firmware that serves disk images. A new mailbox adapter put the firmware's file requests into the host register map.",
         "Worked (TRSDOS boots, games play). The IO controller is **9.5K LUTs**, of which the firmware ROM is 7.2K synthesised as logic. It served only DMK/HDV images, which Linux can do itself. Replaced by V2."],
        ["**V2** Host-served sectors (4304)",
         "The IO controller and its mailbox removed. `bvf_fdc` hands the WD1793's and WD1010's sector requests to the daemon (`diskimg.py`, a port of the firmware's DMK code), one request per sector.",
         "**9,226 LUTs (40 %)**: 9.5K LUTs and 12 block RAMs freed. Identical disk images verified against the firmware's C code. Cost: one Linux round trip per sector instead of per track (latency work, section 10)."],
        ["**V3** + CP-400 (4307, 4308)",
         "The user's own CoCo 2 core (6809 `cpu09`, SAM, MC6847, two PIAs) as machine 1, with its own CPU; a MiniIDE (`bvf_ide`) for hard disks; the 64 KB RAM shared between the two.",
         "13.7K, later 14.5K LUTs; 79 of 84 block RAMs. Works on the board. `cpu09` alone is 2.9K LUTs, the biggest block of the design. Not a Z80, so it cannot share the CPU of the other machines."],
        ["**V4** DDR probe (4310, 4311)",
         "An AXI master on FIC0 that reads and writes DDR and measures latency, to decide what could live in DDR.",
         "Measured on the board: 256 ns typical read, 1.09 µs worst, 347 MB/s bursts (section 9). Defined the rule used ever after: *CPU-side memory may wait, video memory may not.*"],
        ["**V5** CP-300 + MSX2 (4313)",
         "KdL's OneChip MSX (V9958 VDP, 128 KB VRAM) with its own Z80, VRAM packed into 56 block RAMs, main RAM and ROMs in DDR, a block-RAM pool shared with the CP-300.",
         "Simulated and built (**20.0K LUTs**, 76 block RAMs) but not tried on a board. With the CP-400 added it needs **24.7K LUTs and 87 block RAMs**: it cannot fit (22,956 and 84). Replaced by V7."],
        ["**V6** Cached DDR VRAM (abandoned)",
         "A 128 KB VRAM in DDR behind a small cache, to free 56 block RAMs and about 3.4K LUTs.",
         "Even with the cache the three-machine design stopped at 24.07K LUTs, and VDP blitter commands would run several times slower than on real hardware. Abandoned; branch kept."],
        ["**V7** One shared Z80, MSX1 + ZX + MC-1000 (4316 - 4328)",
         "The MSX2 dropped (2026-11-01). The CP-300, an MSX1 (TMS9918A, 16 KB VRAM), a ZX Spectrum 48K and an MC-1000 share **one T80s**; one block-RAM pool serves all machines; the MSX1's ROMs live in DDR behind a cache.",
         "**21,659 LUTs (94.35 %)** in the final gateware, timing met. Six machines; the margin is 1.3K LUTs. Section 7."],
        ["**V8** Alice with a CPU on the host (4320 onwards)",
         "The Matra Alice's MC6803 is emulated in C on Linux; the fabric keeps the video (the MC-1000's VDG), the VRAM and the sound edge path.",
         "About 60 LUTs and no block RAM for a seventh machine, tested in simulation; not yet run on the board. Sections 7.8 and 8."],
    ], [3.3, 6.0, 7.7], "The architecture variants in the order they were built."),
    ("p", "Three patterns repeat in that table and they are the real design rules of the project:"),
    ("ul", [
        "**Share what a machine does not use at the same time.** One Z80, one RAM, one set of block RAMs, one floppy controller, one frame path, one audio path, one tape path. "
        "Only one machine runs, so a block that is idle in one machine is free for another.",
        "**Move anything that is not real-time to the host.** The IO controller's firmware, the disk images, the file formats, the cassette tapes, the ROM files, and in the end the Alice's whole CPU. "
        "The fabric keeps what has hard timing: video generation, sound edges, bus cycles.",
        "**Measure before moving memory.** The DDR probe was built before any machine was put in DDR; its numbers (and not our intuition) decided that ROMs may be in DDR and VRAM may not.",
    ]),
]
