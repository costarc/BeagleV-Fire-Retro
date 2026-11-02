# MSX1 machine for the BeagleV-Fire multicore

The MSX1 (`../rtl/bvf_msx1.v`) runs on the Z80 that the CP-300 and the ZX Spectrum share (`../rtl/bvf_core_bus.v`). Its parts:

| Path | What |
|---|---|
| `vdp18/` | the TMS9918A: vdp18 by Arnim Laeuger, taken from MSX1fpga (`Multicore/Computers/MSX1fpga/src/video/vdp18`). `vdp18_core.vhd` is changed: only the colour index comes out (the old `video_opt_g = 3`, the palette and the scan doubler are gone), and the pixel enable and the pixel / line counters are ports for the frame capture. Unused files of the folder (palette, 3-bit palettes) are not copied. |
| `ocm/` | the PSG of the OCM-PLD (KdL's OneChip MSX), with the clock enable `ENA21` added by `port_ocm.py` |
| `msx1_psg.vhd` | the PSG with its joystick ports pulled up (they are `inout`) |

## Licences

- **vdp18:** copyright (c) 2006 Arnim Laeuger, redistribution in source and synthesized forms with the notice kept (see the headers); the folder
  also carries the GNU GPL version 2 (`vdp18/COPYING`) it came with.
- **The PSG** (`ocm/psg*.vhd`) comes from the **OCM-PLD (KdL's OneChip MSX, based on the ESE MSX-SYSTEM3 of ESE Artists' Factory)**:
  redistribution and use with the copyright notices kept (the headers are untouched), **not to be sold, nor used in a commercial product or
  activity**. This applies to the MSX1 machine and to any package that contains it (`../package/MSX1-LICENSE.txt`).

## Clocking

Everything runs on the 42 MHz core clock with enables: `ena21` = 45/88 of it (21.477 MHz), the Z80 at `ena21` / 6 (3.58 MHz), the VDP at
`ena21` / 2 (10.74 MHz, its `clk_en_10m7_i`). The PSG counts only when `ENA21` and its `clkena` are set in the same clock, so `clkena` is
`ena21` and the divide-by-6 together (the MSX2 of package 0.11.0 had it one clock late: its PSG ran far too slow).
