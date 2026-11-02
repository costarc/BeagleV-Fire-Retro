#!/bin/sh
# APB3 slave simulation (Icarus Verilog): sh run_apb.sh
set -e
cd "$(dirname "$0")"
export PATH="/c/apps/msys64/mingw64/bin:$PATH"
iverilog -g2012 -o /tmp/tb_apb.vvp tb_apb.v ../rtl/apb_regbus.v ../rtl/bvf_regs.v
vvp /tmp/tb_apb.vvp
