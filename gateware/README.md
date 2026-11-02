# BeagleV-Fire gateware component for the CP-300 (draft, not built)

What is known (from the BeagleV-Fire docs) and what is not. **Nothing here has been run through Libero**:
Libero SoC is not installed on this machine (only MPLAB X and the XC compilers are), and the framework's
own source (`CAPE.v`, `ADD_CAPE.tcl`) could not be read (openbeagle.org is behind a bot check).

## Known

- The framework builds gateware with Libero SoC **v2022.3** (a user report says 2024.1 fails at `FPGA_CCC_C0`);
  entry point `python build-bitstream.py ./build-options/<name>.yaml`, which runs `BUILD_BVF_GATEWARE.tcl`
  with options such as `CAPE_OPTION:<name>`.
- A custom design is a directory under `sources/FPGA-design/script_support/components/CAPE/<NAME>/` made from
  `VERILOG_TEMPLATE`: `HDL/*.v` is pulled into the project automatically, `ADD_CAPE.tcl` stitches the
  component to the RISC-V subsystem, clock and reset, plus constraints and a device tree overlay.
- The cape's `CAPE.v` gets `PCLK`, `PRESETN` and an APB slave (the docs' blinky example). So the CP-300 is
  attached as an APB slave: `rtl/apb_regbus.v` (tested in `sim/run_apb.sh`), not as a hand-made FIC AXI port.
- The board is reprogrammed with `sudo /usr/share/beagleboard/gateware/change-gateware.sh <dir>`.

## Not known (check in the real gateware repo before building)

1. The cape's APB window: base address, size, address width, whether PREADY/PSLVERR exist. `apb_regbus` wants
   20 address bits; with less use `PAGED = 1` (page register at window offset 0xFFC, 4 KB pages) and change
   `host/cp300d.py` `MemRegs` to write the page register before each access.
2. The clock the cape APB runs on (PCLK) and whether a 42 MHz clock for the core can come from the framework's
   clock block. If not, a PolarFire CCC / PF_CCC instance in `ADD_CAPE.tcl` is needed (the configuration
   script of the framework's own CCC is the model; it is the part that failed on 2024.1).
3. Whether the cape component may use as much block RAM as the design needs (see HANDOVER.md, memory budget),
   and which I/O the component owns (the CP-300 needs no pins: no constraint file is needed).
4. The kernel side: UIO support and the base address for the overlay (`CAPE/CP300/CP300.dts`).

## Plan once Libero 2022.3 and the gateware repo are available

1. Fork/clone the gateware repo; `cp -r CAPE/VERILOG_TEMPLATE CAPE/CP300`.
2. Copy into `CAPE/CP300/HDL/`: `rtl/*.v` of this folder, `bvf_core` as the instantiated module in `CAPE.v`
   (APB slave to `apb_regbus`, `irq` to the GPIO or interrupt input if there is one), and the VHDL of
   `files.txt` (Libero imports mixed VHDL/Verilog).
3. `cp300_roms_stub.vhd` stands in for the ROM package (ROMs are loaded at run time).
4. Add `CP300.dts`; build with `CAPE_OPTION:CP300`; copy the bitstream to the board; `change-gateware.sh`.
