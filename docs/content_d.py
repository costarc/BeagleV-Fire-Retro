BLOCKS = [
    # ------------------------------------------------------------------------------------------------ 12
    ("h1", "12. The host side: daemon, protocol and page"),
    ("h2", "12.1 Register access: regs32.c"),
    ("p", "Ten lines of C, compiled on first use with `gcc` and called through `ctypes`, issue real 32-bit loads and stores; a block routine reads a whole frame in one call (a 6,144-word read through `ctypes` word by word would spend its time in call overhead):"),
    ("code", """uint32_t rd32(uintptr_t a)             { return *(volatile uint32_t *)a; }
void     wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
void rdblk(uintptr_t a, uint32_t *dst, size_t words);   // word loop, volatile
void wrblk(uintptr_t a, const uint32_t *src, size_t words);"""),
    ("h2", "12.2 The daemon and its simulator"),
    ("p", "`host/cp300d.py` is standard-library Python only (no pip packages, so the package installs on the stock image). The `Cp300` object mirrors the interface contract: `start()` (the power-on sequence of section 6.3), `set_machine()`, `mount()` / `eject()` for each disk class, "
          "`service()` for the sector mailbox, the FreHD and IDE services, `new_frame()`, `audio_events()` and the tape deck. A `SimRegs` class implements the same register interface against a Python model, so **the daemon and the page can be developed and tested with no hardware** "
          "(`--sim`; `test_cp300d.py` is a test suite built on it). Writing the register file as a replaceable class was probably the best productivity decision of the project: the whole web side was finished before the gateware was."),
    ("h2", "12.3 The pump"),
    ("p", "One `asyncio` task is the hardware loop. Priority order: **anything the hardware blocks on is served before anything the user sees.** Disk, FreHD and IDE requests first (interrupt-driven, 0.5 to 2 ms fallback polling); then the picture (at most once per hardware frame; for each client the XOR of the frame with its previous frame, zlib level 1); "
          "then audio edges; every two seconds dirty disk images are saved. The picture, audio and saving run in a lower-priority path with the register reads, XOR (as big integers) and compression in threads, because the IDE lesson (section 10.4) showed that one slow picture can make a DOS give up on its disk. "
          "When the last browser disconnects the keyboard registers are zeroed, so no key stays pressed."),
    ("h2", "12.4 A bring-up probe built into the product"),
    ("p", "`GET /api/debug` returns the control, status, frame, audio-count and tape registers, the time of 1,000 register reads and of one frame read, a **write-readback test** (an `0xA5A55A5A` pattern and an eight-byte block over the keys registers, to detect byte-store corruption), the interrupt count, "
          "the frame rate, and, since the multi-machine work, **the selected machine's internal state**: the CP-400's 6809 address and floppy card lines, or the shared Z80's bus sampled 32 times (`z80_bus`: address and MREQ/IORQ/RD/WR/M1 flags, so *the address that repeats is where the CPU is*), "
          "and for the Spectrum the ULA's last fetches. The probe writes nothing that disturbs a running machine, and waits with `await` rather than `sleep` so the daemon keeps serving disk requests. It found four of this project's bugs (L1 to L3, and the MSX disk hang). If you build one thing before your first board bring-up, build this."),
    ("h2", "12.5 The web protocol"),
    ("p", "One HTTP server on `asyncio.start_server` with a hand-written WebSocket (about forty lines: handshake, frame encode/decode with client masking, ping/pong). No third-party dependency; no TLS (the board's nginx or Cockpit can terminate it); request bodies above 4 MB get HTTP 413, matching nginx."),
    ("table", ["Endpoint", "Use"], [
        ["`GET /`, `GET /ws`", "the page; the WebSocket"],
        ["`GET /api/state`, `GET /api/debug`", "JSON state (machines, ROM presence, drives, SD files, tape, counters); the probe of section 12.4"],
        ["`POST /api/ctrl`", "`{machine, power, reset, turbo, wp}`: select a machine, the power switch, reset, turbo, write-protect"],
        ["`PUT /api/rom/<name>`", "`system`, `chargen`, `zx48`, `mc1000`, `alice`, `msx1bios`, `msx1p2`, `msx1cart`, `msx1disk`, `cp400bas`, `cp400ext`, `cp400cart`, or `cp400` (a complete image); saved, and the machine is (re)started when its ROMs are complete; wrong sizes get HTTP 400"],
        ["`PUT/GET/DELETE /api/disk/N`, `/api/cocodisk/N`, `/api/msxdisk/N`", "mount (converted to DMK for the CP-300), download, eject"],
        ["`PUT/GET/DELETE /api/ide`, `/api/hd/N`, `/api/sd`", "the CP-400's hard disk image; the CP-300's hard disks; the FreHD SD folder"],
        ["`PUT/DELETE/POST /api/tape`, `GET /api/tape/rec.wav`", "load a tape in any supported format (converted in the daemon), eject, transport commands; fetch the recording as a `.wav`"],
    ], [5.4, 11.6], "The main endpoints."),
    ("p", "WebSocket messages: binary frames carry `type | seq u16 | kind u8 | zlib(payload)` (type 1: 12 KB one-bit frames; type 3: 24 KB colour frames; kind 0 = whole frame, kind 1 = XOR with the previous one) and audio edges `(time u32, level u16) × n`; text messages carry the JSON state "
          "(pushed on connect and on every change). The browser sends `{keys: <hex>}` (the **whole** key state on every change: a lost or reordered message cannot leave a key stuck, and the daemon does no key logic), `{ctrl: ...}` and `{keyframe: 1}`."),
    ("h2", "12.6 The page"),
    ("p", "One self-contained file, no framework, no build step. Keyboard mapping is from *characters* to the machine's *matrix*, not from physical keys, with a table of how each original keyboard types its shifted symbols; the Alice has its AZERTY variants; an on-screen keyboard from the same table serves a tablet. "
          "Audio needs a user gesture, so the Sound button creates the `AudioContext`. URLs are relative, so the page works under `/cp300/` behind nginx. Drive names are inserted with `textContent`. The page title and the Cockpit entry are both \"Retro Computers\"."),

    # ------------------------------------------------------------------------------------------------ 13
    ("h1", "13. Delivery: device tree, build, package, installer"),
    ("h2", "13.1 The device-tree overlay"),
    ("code", """&{/chosen} { overlays { CP300-GATEWARE = "GATEWARE_GIT_VERSION"; }; };      // the identity the OS can read

&{/fabric-bus@40000000} {
    cp300: cp300@41000000 { compatible = "generic-uio"; reg = <0x0 0x41000000 0x0 0x100000>;
                            clocks = <&fabric_clk3>; interrupt-parent = <&plic>; interrupts = <126>;
                            status = "okay"; };
};"""),
    ("ul", [
        "`/chosen/overlays/CP300-GATEWARE` is how the board reports which gateware is loaded. The installer and the Cockpit page read it to decide \"is this design loaded or did someone flash another?\".",
        "`generic-uio` makes `/dev/uio0` with name `cp300`; the systemd unit refuses to start the daemon unless `/sys/class/uio/uio0/name` reads `cp300`, so a different gateware can never be driven by this software. The service runs as an ordinary user; a udev rule grants the device.",
        "`interrupts = <126>`: fabric interrupts are PLIC 118 + n, and the cape's `INT[0]` is `MSS_INT_F2M[8]`. The number was not in any table we had; the board's own working devices (PCIe root port on F2M[1] = PLIC 119, the IHC mailbox on F2M[62] = 180) were taken as the reference.",
    ]),
    ("h2", "13.2 Building the gateware"),
    ("fig", "fig15_delivery.png", "From the repository to a running board. The identity string and the package version are raised for every gateware release.", 16.0),
    ("ol", [
        "Clone the board's gateware framework at the commit of its stock gateware (`943f37f`, 2025.10-13) and generate the MSS configuration with `pfsoc_mss`; build the HSS at the commit the framework pins.",
        "`python gateware/make_cape.py <framework>` adds `CAPE_OPTION:CP300`: it copies the template cape, replaces its register block with this design and a PLL, adds `PREADY`/`PSLVERR` and the AXI ports to the cape, routes the interrupt, stages the HDL (stripping `translate_off` blocks that Libero's parser ignores) and writes the import script and the overlay. **Every edit of the template must match exactly once or the script stops** (L5).",
        "Run the framework's build in Libero SoC 2026.1 with a new `DESIGN_VERSION` (about 13 to 15 minutes; the log is written only at the end). The framework needs `AUTO_COMPILE_POINT:false` before synthesis: with automatic compile points Synplify crashed loading a compile point's interface model. "
        "The Synplify licence is node-locked, so **one build at a time per machine**.",
        "Build the overlay image `mpfs_dtbo.spi` (the framework's overlay generator with `dtc`, in WSL), giving it the identity `2025.10-13-g943f37f-<DESIGN_VERSION>-CP300`.",
        "`package/build_package.py --gateware <dir> --version X.Y.Z` from a **clean committed tree**: a reproducible `tar.gz` (sorted entries, fixed owner and time) and a SHA-256.",
    ]),
    ("p", "Two rules carry most of the weight. **Pin the framework to the stock gateware's version**: a framework newer or older than the bootloader and MSS the board shipped with can give a design that boots to nothing (the `develop` branch turned out to be from 2023, older than the board's gateware). "
          "**The identity string must be unique per design *and per release***, and the design version must differ from what is loaded, or the board will not reprogram; the installer flashes only when the loaded identity differs (an early package used an identity without the design version, so boards never got new gateware)."),
    ("h2", "13.3 The package and the installer"),
    ("p", "The package holds the installer, the load helper, the daemon, the page, `dsk2dmk.py`, the service, nginx and Cockpit files, the two flash images, `VERSION`, `GATEWARE_ID`, `SOURCE.txt` (source URL, commit, checksums), the README, the licences and a disclaimer. The ROMs are never in it. `install.sh` is idempotent and layered by risk:"),
    ("table", ["Layer", "Risk", "Behaviour"], [
        ["Software (`/opt/cp300`, service, udev rule)", "none", "always replaced; `regs32.so` and the Alice emulator are compiled on the board at install"],
        ["Web integration (nginx snippet, Cockpit entry)", "low", "replaced; the stock site file is backed up once, outside `sites-enabled`; one `include` line is added and `--uninstall` removes it"],
        ["**Gateware flash** (bitstream, overlay, HSS)", "**can brick the board**", "only if the loaded identity differs; shows the disclaimer; requires typing `I ACCEPT` (or `--yes`)"],
    ], [5.4, 2.8, 8.8], "The installer's layers."),
    ("p", "Options `--yes`, `--no-flash`, `--no-web`, `--force-flash`, `--check` and `--uninstall [--purge]` make each layer reachable on its own; `--check` changes nothing and reports the installed version, the loaded gateware and the daemon state: the first command a support conversation should ask for. "
          "The service starts only if this gateware is the loaded one: flashing a different design leaves the software dormant, and `cp300-load-gateware` brings the design back. Cockpit gets a sidebar page that opens the web page in a new tab (an https Cockpit cannot frame an http page, and its content-security policy forbids inline scripts)."),

    # ------------------------------------------------------------------------------------------------ 14
    ("h1", "14. Performance and resources"),
    ("table", ["Quantity", "Value", "Note"], [
        ["Machine clock", "42 MHz", "PLL from the 50 MHz PCLK; machines use clock enables (CP-400 15/44, MSX1 45/88, ZX 1/12)"],
        ["Logic (gateware 4328)", "**21,659 of 22,956 4LUT (94.35 %)**", "the margin is 1.3K LUTs; timing met on every build (worst slack of the 42 MHz domain +9.7 ns with the CP-300 alone, +4.9 ns later with DDR)"],
        ["Block RAM", "80 of 84 LSRAM (gateware 4322)", "56 in the pool; the rest in the CP-300 core, the IDE sector buffer and others"],
        ["Largest blocks", "`cpu09` 2,942 LUT; T80s 2.3-2.6K; the pool's muxes ~1.6K", "block-RAM interface logic is ~36 LUTs per block"],
        ["Register window", "1 MB used of 16 MB", "`0x41000000`; FIC0 AXI for DDR, 125 MHz"],
        ["Bulk frame read", "about 1.5 ms (12 KB)", "one `rdblk` call"],
        ["Page frame rate", "CP-300 38-40 fps; CP-400 about 12 fps", "Python XOR and framing are the limit"],
        ["Disk request", "about 35 ms interrupt-to-answer before the latency work", "target a few ms; not yet confirmed on the board"],
        ["DDR read, write", "256 ns, 64 ns typical; 1.09 µs, 520 ns worst", "measured with the probe"],
        ["Build", "13 to 15 minutes in Libero", "on the author's PC"],
    ], [3.4, 5.6, 8.0], "Measured numbers."),
    ("p", "**Where the time goes, in the order we would fix it:** (1) the Python XOR over the frame (do it in C or in the fabric); (2) the 4 ms timer for the picture (a frame interrupt would wake the loop once per frame); (3) the disk path's thread scheduling; (4) the area: the DDR probe is about 1.2K LUTs and is only needed for measuring."),

    # ------------------------------------------------------------------------------------------------ 15
    ("h1", "15. Lessons learned"),
    ("p", "L1 to L8 are from the first port and still hold; L9 to L16 came with the other machines."),
    ("h3", "L1. The window has no byte strobes"),
    ("p", "*Symptom:* a written word read back as one byte repeated in all four lanes; data through the window was corrupt. *Cause:* the window is an APB3 bus with no `PSTRB`; a CPU byte store sends the whole data bus, and Python's `memcpy` and `struct.pack_into` perform byte stores on this core. "
          "*Rule:* prove 32-bit read/write integrity with a probe before anything else, and make \"never a byte access\" a property of one small module."),
    ("h3", "L2. Reset order across a held state"),
    ("p", "The machine never started although every register looked right: the slot-table registers are cleared while `run = 0`, and the daemon had published them first and then released `run`. *Rule:* write down which registers belong to which reset domain and make the init sequence follow it (section 6.3)."),
    ("h3", "L3. Torn frames"),
    ("p", "A reader of a fabric-written buffer needs a consistency check designed in, not retrofitted (section 11.2)."),
    ("h3", "L4. The toolchain version is part of the design"),
    ("p", "Framework, MSS configuration, bootloader and synthesis tool must be a matching set. Identify the exact stock build first, match it, and treat every deviation (here: an unofficial Libero version needing two scripted edits) as a known risk in the disclaimer."),
    ("h3", "L5. A patch step that can find nothing must be an error"),
    ("p", "`make_cape.py` connected the interrupt with an exact-text replace that matched nothing, and a package shipped with the interrupt tied to zero; nobody noticed because nothing used it yet. Every edit of a vendor template must match exactly once or stop the script. "
          "Likewise a small array with a reset was inferred as RAM and rejected by Libero (`MF682`), and `translate_off` pragmas were ignored: script the adaptations so that they are reproducible."),
    ("h3", "L6. Systems integration is half the work"),
    ("p", "None of these were gateware bugs: a duplicate default server in nginx because a backup file had been left in `sites-enabled`; the Cockpit page stuck at \"checking\" because of its content-security policy; an https page that cannot frame an http one; a path prefix that broke absolute URLs; line endings carried from Windows. Budget as much for the host's stock software as for the core."),
    ("h3", "L7. Build the whole host side against a simulator first"),
    ("p", "`SimRegs` made the daemon and the page testable off-board; when hardware arrived the only failures were interface ones, which a probe like `/api/debug` isolates."),
    ("h3", "L8. Level semantics beat event semantics"),
    ("p", "Keys as full masks, `changed` as the XOR of two registers, a request as a toggle pair: each removes a class of lost-event bugs at no cost."),
    ("h3", "L9. A bench built from the same belief as the design proves nothing about the belief"),
    ("p", "The MSX disk interface passed its simulation and failed three times on the board (section 10.3): the test program had been written from the same understanding of the interface as the gateware. The only test that can find a wrong belief is the real driver. "
          "*Rule:* for any device with a driver you did not write, disassemble the driver first, and make the real ROM the test."),
    ("h3", "L10. A design that works or not depending on the build"),
    ("p", "The ZX Spectrum picture is black on gateware 4326 and 4327 and correct on 4325 and 4328; the Spectrum logic is identical in all of them and the simulation always shows the picture. The only changed RTL was in the MSX1. Timing was met on every build, so the timing report is not flagging it. "
          "We could not isolate the cause in the time available; it looks like a hardware dependency of the single-read-port arrangement that simulation cannot see (read-during-write behaviour of the block RAMs, or a path that is not what the constraints say). "
          "*What we can say:* put observability in before you need it (the debug register and the bus sampler found the MSX hang in one look; the Spectrum's ULA word showed the symptom but not yet the cause), "
          "and **treat \"timing met\" as necessary, not sufficient, for a design that shares one memory port between two clients.**"),
    ("h3", "L11. The simulation is an oracle only if it runs the real software"),
    ("p", "The CP-400's hard disk could be debugged without the board once the simulation ran the DOS on the user's real sectors and printed exactly the board's screen. Then iterating on the word-order rule took minutes, not flash cycles."),
    ("h3", "L12. A bit that never shows"),
    ("p", "A register bit (bit 2 of the IDE request kind) never appeared on the board while it did in simulation and in the netlist. Do not spend a day on it: encode around it, make the host tolerant, write it down, and move on."),
    ("h3", "L13. Area is the real specification"),
    ("p", "The MSX2 was a fine design that could not exist next to the other machines. Every machine added after it was chosen by what fits: the 94 % LUT figure is not an accident but the result of choosing smaller machines (MSX1 over MSX2) and moving work off the chip (disk firmware, the Alice's CPU). "
          "Keep a running table of LUTs and block RAMs per block (Figure 3 and section 14), and refuse a feature whose cost you have not measured."),
    ("h3", "L14. Measure the memory before you put a machine in it"),
    ("p", "The DDR probe cost one gateware build and decided the memory architecture of three machines in one afternoon of measurements. Without it we would have argued from datasheets."),
    ("h3", "L15. Share the CPU, but write down its bus-cycle rules"),
    ("p", "A shared T80s works because every machine accepts the same cycle shape: writes at the end of /WR, `$FF` on the interrupt acknowledge, data taken at the enable. Each of those rules was found as a bug in one machine and then applied to all."),
    ("h3", "L16. The build farm is one licence"),
    ("p", "The synthesis licence is node-locked: one build at a time on the machine, so parallel sessions must serialise their builds and keep their own framework copies (their run scripts delete the working folder first). Keep every run script, overlay script and log of every gateware you flash."),

    # ------------------------------------------------------------------------------------------------ 16
    ("h1", "16. What is verified and what is not"),
    ("p", "State on 2 November 2026, gateware 4328, package 0.14.5. **Board** = seen running on the author's BeagleV-Fire (Ubuntu 24.04 image of 2025-07-21, stock gateware 2025.10-13). **Sim** = ModelSim, Icarus or the Python tests on the PC."),
    ("table", ["Machine / feature", "Verified on the board", "Simulated only", "Never run / unknown"], [
        ["CP-300", "boots TRSDOS and LDOS, games, keyboard, sound, FreHD boot disk + SD images, `DIR` on hard disks", "-", "the latency fix of section 10.2"],
        ["CP-400", "BASIC, MiniIDE + HDB-DOS (`DIR`), the 507 MB OS-9 image boots, floppy: Disk BASIC banner and 340 sector reads with a CoCo image", "floppy `DIR`/`LOADM` end to end", "IDE sector writes (refused), joysticks, serial"],
        ["MSX1", "Elevator Action cartridge, BASIC, **MSX-DOS boots from a floppy image (0.14.4)**", "tape input", "other disk-interface layouts, FORMAT, a cartridge larger than 32 KB"],
        ["ZX Spectrum 48K", "boots to the TK90X screen on gateware 4325 and 4328", "the picture on every build", "**black screen on 4326 and 4327 (L10)**; tape with real programs"],
        ["MC-1000", "BASIC prompt", "boot to `OK` at 1.5 s", "-"],
        ["Alice (MC-10)", "-", "the emulator (93 checks, MC-10 ROM to the prompt), the fabric half (prompt, semigraphics, RG6)", "the emulator on the board, sound jitter, field sync"],
        ["Tape, all machines", "-", "unit bench; the MSX1's cassette input counted by a Z80", "real tapes: header lengths and polarities"],
        ["Installer, flash", "the software path; the \"already loaded, do not flash\" path; the user's install and flash of each package", "-", "recovery with a FlashPro programmer; `--force-flash` and \"another gateware, and back\""],
    ], [2.4, 6.0, 4.4, 4.2], "Verification status."),
    ("p", "Flashing the board rewrites its bootloader with no fallback; the README and the package carry a disclaimer, and the installer asks for explicit acceptance."),

    # ------------------------------------------------------------------------------------------------ 17
    ("h1", "17. A checklist for other projects"),
    ("p", "For any design that pairs an FPGA block with a CPU running an OS: a retro core, a sensor front end, a codec, an accelerator, a test instrument."),
    ("h3", "Interface"),
    ("ol", [
        "Choose **one memory-mapped register file** as the contract, plus **bulk windows** hanging off the same decoder, and version it with an ID register the software checks first.",
        "Assume **32-bit, no-byte-strobe** access until proven otherwise; put all access in one tiny C helper.",
        "Classify every flow: *state* (whole-value writes), *stream* (double buffer + counter, or a HOLD), *events* (timestamped FIFO), *request/response* (a mailbox with toggles). Do not force them into one mechanism.",
        "Cross clock domains once, at the bridge, with a toggle handshake. Use level/idempotent semantics for what the host sets, counters for what it observes.",
        "Document the **read latency** convention at the top of the register file. Give the host a **probe**, and add visibility (bus sampler, debug word) for every block that has a state you cannot otherwise see.",
    ]),
    ("h3", "Architecture"),
    ("ol", [
        "Share what is never used at the same time (CPU, RAM, pools of block RAM, controllers) and write the rules of the shared interface down.",
        "Move everything that is not hard real-time to the host, including, when the numbers say so, a whole CPU. Keep video generation, sound edges and bus cycles in the fabric.",
        "Measure the slow memory before you move anything into it, and apply one rule: *CPU-side memory may wait, video memory may not.*",
        "Keep a running table of area per block. The chip's size is the real requirement document.",
    ]),
    ("h3", "Host software, platform and delivery"),
    ("ol", [
        "Develop the host against a **simulated register file** first; serve the hardware before the user; prefer a web UI for a headless device; keep format knowledge out of the RTL.",
        "Identify the platform's stock build and match it exactly. Make the OS discover the design (device-tree overlay with a name and an identity), make the service conditional on it.",
        "Ship a package and an installer layered by risk, with `--check` and an explicit acknowledgement before any irreversible step.",
        "Test a modelled device with its **real driver**, not with a test written from your own understanding of it.",
    ]),

    # ------------------------------------------------------------------------------------------------ appendices
    ("h1", "Appendix A. Register map"),
    ("p", "Byte offsets in the window (`rtl/bvf_regs.v`, ID `0x43503005`). The daemon (`host/cp300d.py`) and the gateware must carry the same ID."),
    ("table", ["Offset", "Name", "Contents"], [
        ["`00` r", "ID", "`0x43503005`"],
        ["`04` rw", "CTRL", "b0 run (0 = hold), b1 reset pulse, b2 turbo, b3 write-protect all, b6 frame hold, b7 COLD pulse (power-on: clear RAM), b9:8 and b5:4 machine (0 CP-300, 1 CP-400, 2 MSX1, 3 ZX, 4 MC-1000, 5 Alice)"],
        ["`08` r", "STATUS", "b1 FreHD command pending, b2 disk request pending, b3 request is a write, b5 audio FIFO lost, b6 frame buffer latest / no frame being written, b7 sector buffer copy running"],
        ["`0C`, `10` rw", "KEYS_LO, KEYS_HI", "key matrix bits 31:0 and 63:32 (bit = 8 × row + column)"],
        ["`14` r", "FRAME", "[15:0] frame counter, [16] buffer holding the newest frame"],
        ["`18` rw, `1C` rw", "AUDIO, AUDIO_HEAD", "FIFO count; head `{level, time}`, a write pops it"],
        ["`20` rw", "KEYS2", "[23:0] the MSX matrix rows 8..10 (bits 64..87)"],
        ["`40` r", "REQ", "b0 read sector, b1 write sector, b2 read address, b3 side, b5:4 drive, b6 deleted mark, b7 hard-disk request, then head, track, sector"],
        ["`44` rw", "ACK", "b0 the buffer belongs to the host; b8 found, b9 CRC error, b10 deleted mark"],
        ["`48` rw", "DRIVES", "b3:0 floppy ready, b7:4 floppy write-protected, b9:8 hard disk ready, b11:10 hard disk protected (kept while run = 0)"],
        ["`50`-`5C`", "IDE_REQ, IDE_LBA, IDE_ACK, IDE_CFG", "the CP-400's MiniIDE: request kind, LBA, completion + error, cartridge / disk / MSX1-interface present"],
        ["`60`-`94`", "DDR probe", "CTRL (mode, start), ADDR, WDATA, COUNT, RDATA, LAT_MIN/MAX/SUM, TOTAL, RESULT, T42"],
        ["`98`, `9C`", "FRH_REQ, FRH_ACK", "the FreHD command interface"],
        ["`A0` rw", "ALICE", "[7:0] the `$BFFF` latch (b7 DAC); read: b8 = VRAM window busy"],
        ["`A4`-`B0`", "TAPE", "control, play push, record count, record data"],
        ["`B4` r", "DEBUG", "CP-400: 6809 address and floppy lines; other machines: the shared Z80's bus (`[31:24]` data, `[20:16]` M1/WR/RD/IORQ/MREQ, `[15:0]` address); ZX: ULA attribute and bitmap bits, last attribute write"],
    ], [2.4, 3.6, 11.0], "Registers."),

    ("h1", "Appendix B. Gateware history"),
    ("table", ["Gateware", "Package", "Content", "4LUT"], [
        ["4302 / 4303", "0.3.0 / 0.4.0", "CP-300 + IO controller; the disk interrupt on the board", "~19K (78 %)"],
        ["4304", "-", "IO controller removed; host serves the sectors", "9.2K"],
        ["4307", "0.6.0", "+ CP-400", "13.7K"],
        ["4308", "0.7.0", "+ MiniIDE", "14.5K"],
        ["4310 / 4311", "0.8.0 / 0.9.0", "DDR probe; power cycle (COLD)", "16.0K"],
        ["4312", "0.10.0", "FreHD command interface", "-"],
        ["4313", "0.11.0", "CP-300 + MSX2 (V9958), own Z80, packed VRAM", "20.0K (87 %)"],
        ["4316", "-", "trial: shared Z80, MSX1 + ZX", "19.5K (85 %)"],
        ["4320 / 4321", "0.12.0 / 0.12.1", "six machines; MSX1 first-pixel fix", "20.7K / 20.8K"],
        ["4322", "0.13.0", "tape, MSX1 disk interface", "21.4K (93 %)"],
        ["4323", "0.14.0", "CP-400 floppy controller", "21.6K"],
        ["4324 - 4328", "0.14.1 - 0.14.5", "SAM page-1 fix + debug register; MSX disk drive select, /DRQ, page-2 decode; ZX debug word", "21.66K (94.35 %)"],
    ], [2.6, 3.0, 8.4, 3.0], "Gateware and package versions."),

    ("h1", "Appendix C. Sources and licences"),
    ("table", ["Part", "Origin", "Licence"], [
        ["CP-300 core (`cp300core/`)", "derived from the open HT1080Z core; the CP-300 FPGA project", "GPL v3"],
        ["T80 (`third_party/T80`)", "mist-devel/T80", "see the repository"],
        ["CP-400 core (`cp400/`)", "the author's CP400_COLOR_FPGA: Victor Trucco's Multicore core (based on Mark McDougall's PACE); `cpu09` by John Kent", "Trucco's files BSD-style; `cpu09` GPL v3"],
        ["MC-1000 VDG (`mc1000/`)", "Victor Trucco's MC1000 core, renamed", "BSD-style"],
        ["TMS9918A (`msx1/vdp18/`)", "Arnim Laeuger, from MSX1fpga", "redistribution with the notices kept (the folder also carries GPL v2)"],
        ["PSG (`msx1/ocm/`)", "KdL's OCM-PLD, based on the ESE MSX-SYSTEM3 of ESE Artists' Factory", "**not to be sold nor used in a commercial product or activity**; headers kept"],
        ["MC6803 emulator (`alice/emu`)", "written here, from MAME's `mc10.cpp` / `m6801.cpp` as the reference", "GPL v3 with the project"],
    ], [4.2, 8.0, 4.8], "Third-party parts. The combined bitstream includes the non-commercial PSG, so the project stays non-commercial (a decision of the owner, stated in the README and the package). No ROM image is ever committed or packaged."),
]
