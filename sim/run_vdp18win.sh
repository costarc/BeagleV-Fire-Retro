#!/bin/sh
# The vdp18 alone (text mode): where the picture window of bvf_msx1.v puts the first lit pixel.  sh run_vdp18win.sh
set -e
cd "$(dirname "$0")"
HERE=$PWD
MS=/d/Microchip/Libero_SoC_2026.1/Libero_SoC/ModelSim_Pro/win32acoem
export LM_LICENSE_FILE='D:/Microchip/License.dat'
export SALT_LICENSE_SERVER='D:/Microchip/License.dat'
W=/tmp/vdp18win
rm -rf $W && mkdir -p $W && cd $W
m() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
B=$HERE/..
"$MS/vlib.exe" work >/dev/null
for f in vdp18_pack-p vdp18_clk_gen vdp18_hor_vert vdp18_ctrl vdp18_cpuio vdp18_addr_mux vdp18_pattern vdp18_sprite vdp18_col_mux vdp18_core; do
	"$MS/vcom.exe" -93 -quiet "$(m $B/msx1/vdp18/$f.vhd)"
done
"$MS/vlog.exe" -quiet "$(m $HERE/tb_vdp18win.v)" "$(m $B/rtl/bvf_fb.v)"
"$MS/vsim.exe" -c -quiet tb_vdp18win -gFIX=${FIX:-0} -do "set NumericStdNoWarnings 1; run -all; quit -f"
