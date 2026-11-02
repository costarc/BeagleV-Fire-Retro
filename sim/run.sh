#!/bin/sh
# BeagleV-Fire host side simulation (Icarus Verilog): sh run.sh
set -e
cd "$(dirname "$0")"
export PATH="/c/apps/msys64/mingw64/bin:$PATH"
iverilog -g2012 -o /tmp/tb_bvf.vvp tb_bvf.v ../rtl/axil_regbus.v ../rtl/bvf_regs.v ../rtl/bvf_fb.v \
	../rtl/bvf_pool.v ../rtl/bvf_fdc.v ../rtl/bvf_audio.v
vvp /tmp/tb_bvf.vvp | tail -60
iverilog -g2012 -o /tmp/tb_fb4.vvp tb_fb4.v ../rtl/bvf_fb.v ../rtl/bvf_pool.v
vvp /tmp/tb_fb4.vvp | tail -12
iverilog -g2012 -o /tmp/tb_ide.vvp tb_ide.v ../rtl/bvf_ide.v
vvp /tmp/tb_ide.vvp | tail -4
iverilog -g2012 -o /tmp/tb_ddr.vvp tb_ddr.v ../rtl/bvf_ddr.v
vvp /tmp/tb_ddr.vvp | tail -3
iverilog -g2012 -o /tmp/tb_idebus.vvp tb_idebus.v ../rtl/bvf_ide.v ../rtl/bvf_regs.v
vvp /tmp/tb_idebus.vvp | tail -3
iverilog -g2012 -o /tmp/tb_ramclr.vvp tb_ramclr.v ../rtl/bvf_ramclr.v
vvp /tmp/tb_ramclr.vvp | tail -3
iverilog -g2012 -o /tmp/tb_msxmem.vvp tb_msxmem.v ../rtl/bvf_msxmem.v
vvp /tmp/tb_msxmem.vvp | tail -3
iverilog -g2012 -o /tmp/tb_frehd.vvp tb_frehd.v ../rtl/bvf_frehd.v
vvp /tmp/tb_frehd.vvp | tail -3
