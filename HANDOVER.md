# Handover: CP-300 on the BeagleV-Fire

**Update 2026-10-31 (gateware 4311, package 0.9.0: CP-300, CP-400, MiniIDE, DDR probe, power cycle; before it 4310, package 0.8.0; before it 4308, package 0.7.0; the CP-400 of 0.6.0 is verified on the board, the MiniIDE is not):** the bitstream holds a second machine, the CP-400
(CoCo 2): machine select in CTRL b5:4, register ID `0x43503003`, ROMs and keyboard in the page, 256 x 192 colour picture. The CP-300 is
unchanged. Details and the resource split: [HANDOVER-multi-machine.md](HANDOVER-multi-machine.md). Because the ID changed, the daemon of this
branch needs this gateware (and the other way round).

**Update 2026-10-30 (branch `feature/remove-io-ctrl`, gateware 4304):** the IO controller is gone. `rtl/bvf_fdc.v` puts the
WD1793 / WD1010 sector requests into the register map (REQ 0x40, ACK 0x44, DRIVES 0x48, sector buffer 0x20000, ID `0x43503002`);
the daemon serves floppy and FreeHD sectors itself (`host/diskimg.py`, a port of `firmware/dmk.c`). The build uses 9,226 of
22,956 LUTs (40%, was ~78%) and 64 of 84 LSRAM, and meets timing; details in [HANDOVER-multi-machine.md](HANDOVER-multi-machine.md).
Packaged as 0.5.0 (`releases/`, gateware id `2025.10-13-g943f37f-4304-CP300`). **Checked on the board (2026-10-30):** installed, TRSDOS boots
and lists drive 0 (per-sector reads), and a BASIC `SAVE` works (sector writes). FreeHD checked too: a BASIC program wrote a 0-255 pattern to sector 5 of cylinder 3 through ports C8-CF and read it back (errors 0);
the daemon's image has it at sector index 389 = (3 x 4 + 0) x 32 + 5. Not yet checked: a save that survives a reset.
**The CP-500 ROM's keyboard is PC-style** (shift+2 = `@`, `"` = shift+`'`, `-` and `=` on matrix bits 42 and 45); the page's map was the Model III's
and typed `*` for `"`. Fixed in 0.5.1 (`host/web/index.html`); the 0.5.0 page still has it. Passages below about the IO controller, the data slot mailbox, the track RAM, the slot table and the
ID `0x43503001` describe 0.3.0 / 0.4.0; the daemon of this branch must go with the gateware of this branch (the older
gateware has a different register map).

State at package 0.3.0 (2026-10-28). The README is the user documentation, [BUILDING.md](BUILDING.md) the build procedure;
this lists what is open.

## Changes in 0.3.0

- **Disk request interrupt.** `make_cape.py` now really connects `irq` to the cape's `INT[0]` (in 0.2.0 an exact-text replace
  missed the template's `24'h0` and left it at zero; every template edit now has to match exactly once). The overlay declares
  it (`interrupts = <126>`: `INT[0]` is `MSS_INT_F2M[8]`, fabric interrupts are PLIC 118 + n, checked against the board's PCIe
  root port = 119 on `F2M[1]` and IHC mailbox = 180 on `F2M[62]`). The daemon waits on `/dev/uio0` and unmasks after each
  request; on a gateware without the interrupt (unmask gives `EIO`) it polls as before. `/api/debug` shows `irq` and `irqs`.
- **Frame resync.** The page checks `seq` and asks for a whole frame (`{"keyframe":1}`) when an XOR frame cannot be applied;
  before, a decode error left a wrong picture until the page reconnected.
- **`/api/debug`** no longer writes `CTRL` (it used to start a stopped machine for a moment), puts the keys back, and measures
  the frame rate without blocking the daemon (the old one-second `sleep` could stall a disk request past the firmware's timeout).
- **`PAGED` bridge mode** is simulated (`sim/tb_apb.v`, a 4 KB window with the page register).
- **Gateware identity** now carries the design version: `2025.10-13-g943f37f-4302-CP300` (`DESIGN_VERSION` 4302), so the
  installer flashes the new gateware on a board that has 0.2.0's.

## Done and checked on a board

- The gateware (APB bridge, registers, frame capture, disk mailbox, audio FIFO) builds in Libero SoC 2026.1 on the framework commit
  `943f37f`, meets timing and fits the MPFS025T (78% LUT, 88% block RAM). The image boots the board, `/dev/uio0` appears, the ID
  register reads `0x43503001`.
- The daemon runs the CP-300 on the real fabric: TRSDOS 1.3 boots from a disk image, a game plays, the keyboard and the sound work,
  through nginx (`/cp300/`) and from the Cockpit sidebar entry.
- The package (`package/`) with the installer, the load helper and the disclaimer; the installer's software path and the "gateware
  already loaded, do not flash" path ran on the board.
- **The disk request interrupt** (2026-10-28, package 0.4.0, gateware `2025.10-13-g943f37f-4303-CP300`): the overlay gives
  `/dev/uio0` PLIC 126 (`/proc/interrupts`: `SiFive PLIC 126 ... cp300`), the daemon logs `disk requests by interrupt`, and
  `/api/debug` shows `"irq": true` with `irqs` rising as the boot disk is read (6 interrupts for the first 2 requests, 0 errors).
  The polling fallback was checked against the 0.2.0 gateware (unmask gives `EIO`).

## Not done / not verified

1. **The flash-and-reboot path of the installer** (`--force-flash`) and **another gateware and back** have not been run on a board.
2. **Frame rate:** about 40 fps in the page against the 60 Hz hardware. The daemon's Python (zlib of the XOR frame, WebSocket) is
   the limit; the bulk read of a frame itself takes 1.5 ms.
3. **Saving to a disk image** was not checked end to end after a reset.
4. **Libero SoC 2026.1 is not officially supported** by the framework; the build needs two edits of a scratch copy (BUILDING.md,
   step 5). A build on 2025.2 would remove that doubt.
5. **No fallback when flashing** (the board's own mechanism keeps none). A FlashPro5/6 recovery was not tried.
6. Ideas: embed the page in Cockpit through Cockpit's HTTP and WebSocket channels (the browser refuses an `http` frame inside the
   `https` Cockpit page, so the sidebar entry opens the page in a new tab);
   a bus timeout in `apb_regbus.v` so a dead clock cannot hang the bus; a prebuilt `regs32.so` for boards without `gcc`.

## Decisions

- Track RAM is little endian (the Pocket's is big endian) so Linux sees bytes in order. ROM words stay big endian packed
  (`ht1080z` expects the first byte in bits 31:24); the daemon does the packing.
- Pixel x of a frame word is bit x mod 32, leftmost pixel least significant, so the daemon hands the browser plain LSB-first bytes.
- All register access goes through `host/regs32.c` (real 32-bit loads and stores): the window has no byte strobes, and Python's
  byte-wise stores corrupt every word.
- (0.3.0/0.4.0 only) The IO controller had to be released (`CTRL.run = 1`) before the slot table was published. Now the daemon sets
  `DRIVES` while `run = 0` (they are kept) and then releases the core.
- Disk uploads are converted to DMK in the daemon with `tools/dsk2dmk.py`; the images are kept in RAM and saved on change.
