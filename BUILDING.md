# Building the BeagleV-Fire gateware and package

This is the procedure that produced the gateware in the released package. You only need it to rebuild the gateware; to use the
CP-300 install the package ([README](README.md)).

**Reading this first:** the build uses a Libero SoC version that the BeagleV-Fire gateware framework does not officially
support, and a framework commit chosen to match one specific stock gateware. It worked for the author; expect to adapt it.
Flashing the result can brick the board ([disclaimer](README.md#disclaimer-you-can-brick-your-board)).

## What was used

| | |
|---|---|
| Gateware framework | [`git.beagleboard.org/beaglev-fire/gateware`](https://git.beagleboard.org/beaglev-fire/gateware) at commit `943f37f` (`2025.10-13-g943f37f`), the version of the stock gateware (`bbb.io-gateware 1.20260506.1`) the board ran |
| Libero SoC | 2026.1 on Windows, free Silver licence (nodelocked to the C: drive serial). The framework lists 2022.3 to 2025.2; the check is bypassed (see below) |
| Bootloader (HSS) | [`polarfire-soc/hart-software-services`](https://github.com/polarfire-soc/hart-software-services) commit `4bea7e2` with the three patches of the framework's `patches/hss`, built with SoftConsole 2022.2 (Linux, in WSL) |
| Other | Python 3, git, `dtc` (WSL/Linux), `gcc` is not needed on the PC |

`943f37f` and `4bea7e2` are what `build-options/default.yaml` of that framework commit pins. If your board runs another stock
version, check out the framework commit of *that* version instead (`git describe` of the framework = the version in
`/proc/device-tree/chosen/overlays/` of the stock gateware).

## Steps

Paths are examples. In Libero's script arguments use forward slashes.

**1. The framework.** A full clone (the version string comes from `git describe`):

```
git clone https://git.beagleboard.org/beaglev-fire/gateware.git gw
cd gw && git checkout 943f37f
```

**2. The MSS (processor subsystem) sources and configuration.**

```
git clone -b default sources/FPGA-design/mss.bundle sources/MSS
pfsoc_mss -GENERATE -CONFIGURATION_FILE:sources/MSS/configs/MPFS025T/FCVG484/mpfs-beaglev-fire/MSS_Configuration.cfg -OUTPUT_DIR:work/MSS
```

`pfsoc_mss` is in Libero's `bin64`. It writes `PF_SOC_MSS.cxz` and `PF_SOC_MSS_mss_cfg.xml`.

**3. The bootloader** (Linux or WSL, SoftConsole's RISC-V GCC first in `PATH`, **no distribution RISC-V GCC installed**: it shadows
SoftConsole's and fails with `zicsr` / `inttypes.h` errors):

```
git clone https://github.com/polarfire-soc/hart-software-services.git hss && cd hss
git checkout 4bea7e24f3e5ef1de360a80b0a27abb1eb6134e0
git am <gw>/patches/hss/0001-*.patch <gw>/patches/hss/0002-*.patch <gw>/patches/hss/0003-*.patch
cp <gw>/work/MSS/PF_SOC_MSS_mss_cfg.xml boards/mpfs-beaglev-fire/soc_fpga_design/xml/PF_SOC_MSS_mss_cfg.xml
cp boards/mpfs-beaglev-fire/def_config .config
export SC_INSTALL_DIR=<SoftConsole>; export PATH=$SC_INSTALL_DIR/riscv-unknown-elf-gcc/bin:$PATH
make -j8 CROSS_COMPILE=riscv64-unknown-elf- BOARD=mpfs-beaglev-fire BOOTMODE=1 FPGENPROG=/bin/true
```

The result is `build/bootmode1/hss-envm-wrapper-bm1-p0.hex`. (`FPGENPROG=/bin/true`: the boot mode programmer runs with
`--dryrun`, nothing is programmed.) Put the hex where Libero can read it (for example `<gw>/work/HSS/`).

**4. The CP-300 cape:**

```
python syn/beaglev-fire/gateware/make_cape.py <gw>
```

It adds `CAPE_OPTION:CP300` to the framework: the HDL (the CP-300 core, the CP-400 core of `cp400/`, the MSX1 and the Spectrum on the shared Z80,
the register block and `bvf_fdc`; there is no IO controller), a 50 → 42 MHz PLL core, the overlay and the pin file of the template.
It also removes `translate_off` blocks from the staged VHDL (Libero's parser ignores them) and keeps one array in registers.
It needs the `rtl/T80` submodule (`git submodule update --init rtl/T80`). Every edit of the template `CAPE.v` must match
exactly once or the script stops; the staged `CAPE.v` must have `assign INT[23:0] = {23'h000000, cp300_irq};` (in
package 0.2.0 that edit silently missed and the interrupt was not connected).

**5. Edits to the framework copy** (scratch clone, not committed anywhere):

- In `sources/FPGA-design/BUILD_BVF_GATEWARE.tcl` allow Libero 2026 in the version check (add an `elseif` for `2026`).
- Synplify's automatic compile points must be off (found with the MSX2 gateware; the builds since keep it off: with them on, the mapper crashes loading a compile point's interface model: `Signal 011 in m_generic.exe`). Add before `if !{[info exists ONLY_CREATE_DESIGN]} {` in `BUILD_BVF_GATEWARE.tcl`:

  ```
  configure_tool -name {SYNTHESIZE} -params {AUTO_COMPILE_POINT:false}
  ```

  (`set_option -automatic_compile_point` in `SYNPLIFY_OPTIONS` is refused: Libero manages it.) The Synplify licence is node-locked: only one Synplify (so one build) can run on a machine at a time; use a separate framework copy per session.
- Pin the AXI interconnect core: Libero 2026.1 picks version 3.0.130 for the wildcard, which lacks a parameter the scripts set:

  ```
  grep -rl 'COREAXI4INTERCONNECT:\*' sources | xargs sed -i 's/COREAXI4INTERCONNECT:\*/COREAXI4INTERCONNECT:2.8.103/g'
  ```

**6. Libero.** From `sources/FPGA-design`:

```
libero SCRIPT:BUILD_BVF_GATEWARE.tcl "SCRIPT_ARGS:CAPE_OPTION:CP300 BOARD:mpfs-beaglev-fire BOOTMODE:BM1 PROJECT_LOCATION:<gw>/work/libero TOP_LEVEL_NAME:CP300_943F37F HSS_IMAGE_PATH:<gw>/work/HSS/hss-envm-wrapper-bm1-p0.hex PROG_EXPORT_PATH:<gw>/build MSS_COMPONENT_PATH:<gw>/work/MSS/PF_SOC_MSS.cxz INITIAL_DIRECTORY:<gw> DESIGN_VERSION:4311"
```

Set `LM_LICENSE_FILE` to your licence file. It runs synthesis, place and route and timing, then exports
`build/bitstream/LinuxProgramming/mpfs_bitstream.spi` (about 10 minutes). The log file is written only when it ends: watch
the project folder. `DESIGN_VERSION` must differ from the one loaded on the board, or the board does not reprogram the fabric:
raise it for every gateware release (4301 = package 0.2.0, 4302 = 0.3.0, 4303 = 0.4.0, 4304 = no IO controller, 4307 = with the CP-400, package 0.6.0, 4308 = with the MiniIDE, package 0.7.0, 4310 = with the DDR probe, package 0.8.0, 4311 = with the power cycle, package 0.9.0, 4312 = with the FreHD command interface, package 0.10.0, CP-300 + CP-400; 4313 = CP-300 + MSX2, package 0.11.0; 4314 = used by another build; 4315 = the MSX2 with a VRAM cache, a trial that did not fit; 4316 = CP-300 + CP-400 + MSX1 + Spectrum, trial build).

**7. The overlay image** (Linux or WSL, needs `dtc`, `python3-yaml`, `python3-git`). From `<gw>`, with the framework's
`gateware_scripts`:

```python
import gateware_scripts.generate_gateware_overlays as g
g.get_gateware_git_version = lambda work_dir: "2025.10-13-g943f37f-4311-CP300"   # the string that /chosen/overlays will show
g.generate_gateware_overlays("sources/FPGA-design", "out", "CAPE_OPTION:CP300", "default")
```

This writes `out/mpfs_dtbo.spi`. Copy it next to the bitstream (`LinuxProgramming/`). The string is the gateware's identity,
`<framework version>-<DESIGN_VERSION>-CP300`. The installer flashes only when the loaded identity differs from the package's,
so it must change with every gateware release (0.2.0 used `2025.10-13-g943f37f-CP300`), and it must end in `-CP300`
(`build_package.py` looks for that).

**8. The package:**

```
python syn/beaglev-fire/package/build_package.py --gateware <dir with LinuxProgramming/> --out syn/beaglev-fire/releases --version <v>
```

## Pitfalls found on the way

- The framework's `develop` branch is old (2023); use the commit that matches the board's stock gateware.
- The framework imports only `*.v` files from a cape's `HDL/` folder; `make_cape.py` imports the VHDL from `ADD_CAPE.tcl`.
- Synplify turns a small array with a reset into a RAM and then refuses its initial value (`MF682`): remove the initial value.
- A wrong overlay (device tree) or a bootloader built with another compiler than SoftConsole's can leave the board unable to start.
- The board's register window is a 32-bit APB bus without byte strobes: any software that writes it must use real 32-bit
  stores (see `host/regs32.c`).
