#!/bin/sh
# CP-400 core simulation (ModelSim of Libero): sh run_cp400.sh [frames]
# needs the two ROM images as Intel HEX (the CP400_COLOR_FPGA ones): ROM_BAS, ROM_EXT
set -e
cd "$(dirname "$0")"
HERE=$PWD
MS=/d/Microchip/Libero_SoC_2026.1/Libero_SoC/ModelSim_Pro/win32acoem
export LM_LICENSE_FILE='D:/Microchip/License.dat'
export SALT_LICENSE_SERVER='D:/Microchip/License.dat'
R=/c/Users/roniv/Dev/github/CP400_COLOR_FPGA/FPGA/src/plataform/roms
W=/tmp/${WORK:-cp400work}
rm -rf $W && mkdir -p $W && cd $W
"$MS/vlib.exe" work >/dev/null
for f in cp400_chargen cp400_linebuf cpu09 pia6821 mc6883 mc6847 cp400_core; do
	"$MS/vcom.exe" -93 -quiet "$(cygpath -m "$HERE/../cp400/$f.vhd" 2>/dev/null || echo "$HERE/../cp400/$f.vhd")" 
done
"$MS/vlog.exe" -quiet "$(cygpath -m "$HERE/../rtl/bvf_ide.v" 2>/dev/null || echo "$HERE/../rtl/bvf_ide.v")"
"$MS/vcom.exe" -2008 -quiet "$(cygpath -m "$HERE/tb_cp400.vhd" 2>/dev/null || echo "$HERE/tb_cp400.vhd")"
"$MS/vsim.exe" -c -quiet tb_cp400 -gROM_BAS="$R/cp400bas.hex" -gROM_EXT="$R/cp400extbas.hex" -gFRAMES=${1:-8} ${CART:+-gROM_CART="$R/prologica_hdblba_miniide.hex"} ${ID:+-gID_FILE="$ID"} ${SEC:+-gSEC_FILE="$SEC"} ${TB_GENERICS} ${TYPE_TEXT:+-gTYPE_TEXT="$TYPE_TEXT"} ${KEY_AT:+-gKEY_AT="$KEY_AT"} -do "run -all; quit -f"
