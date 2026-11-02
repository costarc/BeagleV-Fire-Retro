#!/bin/sh
# The cassette recorder alone (rtl/bvf_tape.v): sh run_tape.sh
set -e
cd "$(dirname "$0")"
HERE=$PWD
MS=/d/Microchip/Libero_SoC_2026.1/Libero_SoC/ModelSim_Pro/win32acoem
export LM_LICENSE_FILE='D:/Microchip/License.dat'
export SALT_LICENSE_SERVER='D:/Microchip/License.dat'
W=/tmp/tapebench
rm -rf $W && mkdir -p $W && cd $W
m() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
"$MS/vlib.exe" work >/dev/null
"$MS/vlog.exe" -quiet "$(m $HERE/../rtl/bvf_tape.v)" "$(m $HERE/tb_tape.v)"
"$MS/vsim.exe" -c -quiet tb_tape -do "run -all; quit -f"
