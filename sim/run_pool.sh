#!/bin/sh
# bvf_pool test (ModelSim of Libero): sh run_pool.sh
set -e
cd "$(dirname "$0")"
HERE=$PWD
MS=/d/Microchip/Libero_SoC_2026.1/Libero_SoC/ModelSim_Pro/win32acoem
export LM_LICENSE_FILE='D:/Microchip/License.dat'
export SALT_LICENSE_SERVER='D:/Microchip/License.dat'
W=/tmp/${WORK:-poolwork}
rm -rf $W && mkdir -p $W && cd $W
m() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
"$MS/vlib.exe" work >/dev/null
"$MS/vlog.exe" -quiet "$(m $HERE/../rtl/bvf_pool.v)" "$(m $HERE/tb_pool.v)"
"$MS/vsim.exe" -c -quiet tb_pool -do "run -all; quit -f"
