#!/bin/sh
# The machines on the shared Z80 (ModelSim of Libero): MACH=3 sh run_z80sys.sh [ms]   (bvf_core_bus + AXI model; writes frame.ppm)
#   MACH=0 the CP-300 (test ROM), MACH=2 the MSX1 (C-BIOS: CBIOS = its folder), MACH=3 the ZX Spectrum (ZXROM = a ROM file holding the 48K ROM),
#   MACH=4 the MC-1000 (MCROM = its 16 KB ROM), MACH=5 the Matra Alice (ALICEVRAM = the VRAM + mode image from alice/emu: alice MC10.BIN -dump)
set -e
cd "$(dirname "$0")"
HERE=$PWD
MS=/d/Microchip/Libero_SoC_2026.1/Libero_SoC/ModelSim_Pro/win32acoem
export LM_LICENSE_FILE='D:/Microchip/License.dat'
export SALT_LICENSE_SERVER='D:/Microchip/License.dat'
MACH=${MACH:-3}
CB=${CBIOS:-/c/Users/roniv/Dev/github/openMSX/openMSX/Contrib/cbios}
ZX=${ZXROM:-/c/Users/roniv/Dev/github/Multicore/Computers/ZX_Spectrum-128K/spectrum.rom}
W=/tmp/${WORK:-z80sys$MACH}
rm -rf $W && mkdir -p $W && cd $W
MC=${MCROM:-/c/Users/roniv/Dev/github/Multicore/Computers/MC1000/ROMs/mc1000.rom}
case $MACH in 2) python3 "$HERE/gen_z80_roms.py" 2 . "$CB";; 3) python3 "$HERE/gen_z80_roms.py" 3 . "$ZX";; 4) python3 "$HERE/gen_z80_roms.py" 4 . "$MC";; 5) python3 "$HERE/gen_z80_roms.py" 0 . ; cp "${ALICEVRAM:-$HERE/alice_vram.hex}" alice_vram.hex;; 6) python3 "$HERE/gen_z80_roms.py" 6 .;; 7) python3 "$HERE/gen_z80_roms.py" 7 .;; *) python3 "$HERE/gen_z80_roms.py" 0 .;; esac
m() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
R=$HERE/..
B=$HERE/..
"$MS/vlib.exe" work >/dev/null
printf 'package sim_trace_cfg is
  constant TRACE_FROM : time := 0 ms;
  constant TRACE_TO   : time := 0 ms;
end package;
' > sim_trace_cfg.vhd
"$MS/vcom.exe" -93 -quiet sim_trace_cfg.vhd
for f in T80_Pack T80_Reg T80_MCode T80_ALU T80 T80s; do "$MS/vcom.exe" -93 -quiet "$(m $R/third_party/T80/$f.vhd)"; done
# the CP-300 (as in the gateware: make_cape.py)
"$MS/vcom.exe" -2008 -quiet -suppress 1339,1236 "$(m $R/cp300core/cp300_roms_stub.vhd)"
for f in cp300core/cp300/cp300_rom.vhd cp300core/fdc/wd1793.vhd cp300core/hdc/wd1010.vhd cp300core/ht1080z/videoctrl.vhd cp300core/ht1080z/ps2reader.vhd cp300core/ht1080z/ps2kbd.vhd; do
	"$MS/vcom.exe" -2008 -quiet -suppress 1339,1236 "$(m $R/$f)"
done
"$MS/vcom.exe" -2008 -quiet -suppress 1339,1236 "$(m $R/cp300core/ht1080z/ht1080z.vhd)" "$(m $B/rtl/ht1080z_bvf.vhd)"
for f in cp400_chargen cp400_linebuf cpu09 pia6821 mc6883 mc6847 cp400_core; do "$MS/vcom.exe" -2008 -quiet -suppress 1339,1236 "$(m $B/cp400/$f.vhd)"; done
for f in vdp18_pack-p vdp18_clk_gen vdp18_hor_vert vdp18_ctrl vdp18_cpuio vdp18_addr_mux vdp18_pattern vdp18_sprite vdp18_col_mux vdp18_core; do
	"$MS/vcom.exe" -93 -quiet "$(m $B/msx1/vdp18/$f.vhd)"
done
"$MS/vcom.exe" -93 -quiet -suppress 1339,1236 "$(m $B/msx1/ocm/psg_wave.vhd)" "$(m $B/msx1/ocm/psg.vhd)" "$(m $B/msx1/msx1_psg.vhd)"
"$MS/vcom.exe" -93 -quiet "$(m $B/mc1000/mc1000_vdg_pack-p.vhd)" "$(m $B/mc1000/mc1000_vdg_chr.vhd)" "$(m $B/mc1000/mc1000_vdg.vhd)"
"$MS/vlog.exe" -quiet -sv $(for f in bvf_core_bus bvf_regs bvf_fb bvf_fdc bvf_audio bvf_ide bvf_ddr bvf_ramclr bvf_frehd bvf_pool bvf_msx1 bvf_msxmem bvf_zx bvf_mc1000 bvf_tape bvf_cocofdc; do echo "$(m $B/rtl/$f.v)"; done) "$(m $HERE/tb_z80sys.v)"
"$MS/vsim.exe" -c -quiet tb_z80sys -gMACH=$MACH -gRUN_MS=${1:-100} -gTRACE_MS=${TRACE_MS:-0} -gVDPDBG=${VDPDBG:-0} -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f"
