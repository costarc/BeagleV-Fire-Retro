#!/usr/bin/env python3
"""Adds the CP-300 as a cape option (CAPE_OPTION:CP300) to a checkout of the BeagleV-Fire gateware repo.

    python make_cape.py <gateware repo dir>

It copies the framework's VERILOG_TEMPLATE cape, replaces its register block by the CP-300 (bvf_core_apb) plus a
42 MHz PF_CCC fed from PCLK, stages the HDL of this repository next to it and writes ADD_CAPE.tcl and the overlay.
Then:   libero SCRIPT:BUILD_BVF_GATEWARE.tcl "SCRIPT_ARGS:CAPE_OPTION:CP300 ..."   (from sources/FPGA-design)
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
CAPES = os.path.join("sources", "FPGA-design", "script_support", "components", "CAPE")

# (path relative to REPO, VHDL or Verilog)
SOURCES = [
    "rtl/bvf_core_apb.v", "rtl/bvf_core_bus.v", "rtl/apb_regbus.v",
    "rtl/bvf_regs.v", "rtl/bvf_fb.v", "rtl/bvf_fdc.v",
    "rtl/bvf_audio.v", "rtl/bvf_ide.v", "rtl/bvf_ddr.v", "rtl/bvf_ramclr.v", "rtl/bvf_frehd.v",
    "rtl/bvf_pool.v", "rtl/bvf_tape.v", "rtl/bvf_cocofdc.v", "rtl/bvf_msx1.v", "rtl/bvf_msxmem.v", "rtl/bvf_zx.v", "rtl/bvf_mc1000.v",
    "rtl/ht1080z_bvf.vhd", "cp300core/cp300_roms_stub.vhd",
    "cp300core/cp300/cp300_rom.vhd", "cp300core/fdc/wd1793.vhd", "cp300core/hdc/wd1010.vhd",
    "cp300core/ht1080z/ht1080z.vhd", "cp300core/ht1080z/videoctrl.vhd", "cp300core/ht1080z/ps2kbd.vhd", "cp300core/ht1080z/ps2reader.vhd",
    # the CP-400 (CoCo 2) machine: cp400 (the user's CP400_COLOR_FPGA core, see its headers)
    "cp400/cp400_chargen.vhd", "cp400/cp400_linebuf.vhd", "cp400/cpu09.vhd",
    "cp400/pia6821.vhd", "cp400/mc6883.vhd", "cp400/mc6847.vhd",
    "cp400/cp400_core.vhd",
    # the MSX1: vdp18 (TMS9918A, Arnim Laeuger, msx1/vdp18) and the OCM's PSG (licence: msx1/README.md), in compile order
    "msx1/vdp18/vdp18_pack-p.vhd", "msx1/vdp18/vdp18_clk_gen.vhd",
    "msx1/vdp18/vdp18_hor_vert.vhd", "msx1/vdp18/vdp18_ctrl.vhd",
    "msx1/vdp18/vdp18_cpuio.vhd", "msx1/vdp18/vdp18_addr_mux.vhd",
    "msx1/vdp18/vdp18_pattern.vhd", "msx1/vdp18/vdp18_sprite.vhd",
    "msx1/vdp18/vdp18_col_mux.vhd", "msx1/vdp18/vdp18_core.vhd",
    "msx1/ocm/psg_wave.vhd", "msx1/ocm/psg.vhd", "msx1/msx1_psg.vhd",
    # the MC-1000's MC6847 (Victor Trucco's MC1000 core, mc1000)
    "mc1000/mc1000_vdg_pack-p.vhd", "mc1000/mc1000_vdg_chr.vhd", "mc1000/mc1000_vdg.vhd",
]
T80 = ["T80_Pack", "T80_MCode", "T80_ALU", "T80_Reg", "T80", "T80s", "T80se", "T80a"]   # in compile order

# (AXI4 signal, width, direction seen from the master): the fabric master on FIC0 (FIC_0_AXI4_TARGET of the subsystem)
AXI = [("AWID", 4, "o"), ("AWADDR", 38, "o"), ("AWLEN", 8, "o"), ("AWSIZE", 3, "o"), ("AWBURST", 2, "o"), ("AWLOCK", 1, "o"),
       ("AWCACHE", 4, "o"), ("AWPROT", 3, "o"), ("AWQOS", 4, "o"), ("AWVALID", 1, "o"), ("AWREADY", 1, "i"),
       ("WDATA", 64, "o"), ("WSTRB", 8, "o"), ("WLAST", 1, "o"), ("WVALID", 1, "o"), ("WREADY", 1, "i"),
       ("BID", 4, "i"), ("BRESP", 2, "i"), ("BVALID", 1, "i"), ("BREADY", 1, "o"),
       ("ARID", 4, "o"), ("ARADDR", 38, "o"), ("ARLEN", 8, "o"), ("ARSIZE", 3, "o"), ("ARBURST", 2, "o"), ("ARLOCK", 1, "o"),
       ("ARCACHE", 4, "o"), ("ARPROT", 3, "o"), ("ARQOS", 4, "o"), ("ARVALID", 1, "o"), ("ARREADY", 1, "i"),
       ("RID", 4, "i"), ("RDATA", 64, "i"), ("RRESP", 2, "i"), ("RLAST", 1, "i"), ("RVALID", 1, "i"), ("RREADY", 1, "o")]


def _w(w):
    return "[%d:0] " % (w - 1) if w > 1 else ""


AXI_HEADER = "".join("    AXI_M_%s,\n" % n for n, w, d in AXI)
AXI_DECL = "".join("%s %s%s;\n" % ("output" if d == "o" else "input ", _w(w).ljust(8), "AXI_M_" + n) for n, w, d in AXI)
AXI_CONN = "".join("        .m_%s ( AXI_M_%s ),\n" % (n.lower(), n) for n, w, d in AXI)
AXI_TCL = ""      # the cape core has plain ports (a BIF was refused: "not compatible" with FIC_0_AXI4_TARGET); connected per signal
AXI_PINS = """
# FIC_0_AXI4_TARGET of the subsystem: show the bus interface's signals, connect them one by one to the cape's AXI_M_* ports.
# The names SmartDesign gives the shown pins are tried in turn (and logged: the first working form is what the Tcl reference does not say).
proc connect_fic0_signal {sd_name sig} {
    foreach sh [list $sig FIC_0_AXI4_S_$sig] {
        if {[catch {sd_show_bif_pins -sd_name $sd_name -bif_pin_name {BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_TARGET} -pin_names [list $sh]} err]} {
            puts "FIC0 show $sh failed: $err"
        } else {
            puts "FIC0 show $sh ok"
            break
        }
    }
    foreach pn [list BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_TARGET_FIC_0_AXI4_S_$sig BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_TARGET_$sig BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_S_$sig] {
        if {[catch {sd_connect_pins -sd_name $sd_name -pin_names [list $pn CAPE:AXI_M_$sig]} err]} {
            puts "FIC0 connect $pn failed: $err"
        } else {
            puts "FIC0 connect $pn ok"
            return
        }
    }
    error "cannot connect FIC_0_AXI4_TARGET signal $sig"
}
""" + "".join("connect_fic0_signal ${sd_name} %s\n" % n for n, w, d in AXI)

CCC = """create_and_configure_core -core_vlnv {Actel:SgCore:PF_CCC:*} -component_name {PF_CCC_CP300} -params {\\
"GL0_0_IS_USED:true" \\
"GL0_0_OUT_FREQ:42" \\
"GL0_0_FABCLK_USED:true" \\
"PLL_IN_FREQ_0:50" \\
"PLL_REF_CLK_SEL_0:false" \\
"GL0_0_FREQ_SEL:false" }
"""

INSTANCE = """//--------CP-300 core (42 MHz from PCLK)
wire        clk42, pll_lock;
PF_CCC_CP300 pll42 (
        .REF_CLK_0        ( PCLK ),
        .PLL_POWERDOWN_N_0( 1'b1 ),
        .OUT0_FABCLK_0    ( clk42 ),
        .PLL_LOCK_0       ( pll_lock )
        );
wire        cp300_irq;
bvf_core_apb cp300 (
        .pclk   ( PCLK ),
        .presetn( PRESETN ),
        .paddr  ( APB_SLAVE_SLAVE_PADDR ),
        .psel   ( APB_SLAVE_SLAVE_PSEL ),
        .penable( APB_SLAVE_SLAVE_PENABLE ),
        .pwrite ( APB_SLAVE_SLAVE_PWRITE ),
        .pwdata ( APB_SLAVE_SLAVE_PWDATA ),
        .prdata ( APB_SLAVE_PRDATA ),
        .pready ( APB_SLAVE_SLAVE_PREADY ),
        .pslverr( APB_SLAVE_SLAVE_PSLVERR ),
        .clk    ( clk42 ),
        .pll_locked( pll_lock ),
@@AXI_CONN@@        .aclk   ( ACLK ),
        .aresetn( ARESETN ),
        .irq    ( cp300_irq )
        );
"""


def sub_once(pattern, repl, text, what):
    """re.sub that must match exactly once: a template that changed shape stops the script instead of being skipped."""
    text, n = re.subn(pattern, repl, text, count=1, flags=re.S | re.M)
    if n != 1:
        raise SystemExit("%s not found in the template CAPE.v" % what)
    return text


def patch_cape(text):
    # the DDR probe: ACLK, ARESETN and the AXI master ports of the cape
    text = sub_once(r"^    PRESETN,\n", lambda m: m.group(0) + "    ACLK,\n    ARESETN,\n" + AXI_HEADER, text, "PRESETN header port")
    text = sub_once(r"^input         PRESETN;\n", lambda m: m.group(0) + "input         ACLK;\ninput         ARESETN;\n" + AXI_DECL, text,
                    "PRESETN declaration")
    # ports PREADY / PSLVERR
    text = sub_once(r"^([ \t]*)APB_SLAVE_SLAVE_PRDATA,\n", r"\g<0>\1APB_SLAVE_SLAVE_PREADY,\n\1APB_SLAVE_SLAVE_PSLVERR,\n", text,
                    "APB_SLAVE_SLAVE_PRDATA port")
    text = sub_once(r"^output \[31:0\] APB_SLAVE_SLAVE_PRDATA;\n",
                    "\\g<0>output        APB_SLAVE_SLAVE_PREADY;\noutput        APB_SLAVE_SLAVE_PSLVERR;\n", text,
                    "APB_SLAVE_SLAVE_PRDATA declaration")
    # the register block is replaced
    text = sub_once(r"//--------apb_ctrl_status\napb_ctrl_status apb_ctrl_status_0\(.*?\);\n", lambda m: INSTANCE, text,
                    "apb_ctrl_status instance")
    # interrupt: bit 0 of INT (MSS_INT_F2M[8], PLIC 126) follows the disk request level. The template writes the
    # constant as 24'h0; any spelling of it is matched (an exact-text replace missed it in package 0.2.0)
    text = sub_once(r"^assign INT\[23:0\](\s*)=\s*24'h0+;", r"assign INT[23:0]\1= {23'h000000, cp300_irq};", text,
                    "assign INT[23:0]")
    # nothing reads the old control register any more
    text = text.replace("wire   [31:0]  apb_ctrl_status_0_control;\n", "", 1)
    return text


def strip_sim_only(path):
    """Libero's HDL parser does not honour `-- synthesis translate_off`; the staged copy loses those blocks."""
    with open(path, encoding="latin-1", newline="") as f:      # byte-preserving: the OCM files carry UTF-8 (Japanese) comments
        text = f.read()
    pat = (r"^[ \t]*--\s*(?:synthesis|pragma)\s+translate_off.*?"
           r"^[ \t]*--\s*(?:synthesis|pragma)\s+translate_on[^\n]*\n")
    text = re.sub(pat, "", text, flags=re.S | re.M | re.I)
    with open(path, "w", encoding="latin-1", newline="") as f:
        f.write(text)


def keep_in_registers(path, signal):
    """Synplify turns a small array with a reset into a RAM and then refuses its initial value: keep it in registers."""
    with open(path) as f:
        text = f.read()
    decl = re.search(r"^[ \t]*signal\s+%s\s*:[^;]*;[^\n]*\n" % signal, text, flags=re.M | re.I)
    if not decl:
        raise SystemExit("signal %s not found in %s" % (signal, path))
    init = re.sub(r"\s*:=\s*\(others\s*=>\s*\(others\s*=>\s*'0'\)\)\s*;", ";", decl.group(0), count=1)
    attr = ("  attribute syn_ramstyle : string;\n"
            "  attribute syn_ramstyle of %s : signal is \"registers\";\n" % signal)
    with open(path, "w") as f:
        f.write(text[:decl.start()] + init + attr + text[decl.end():])


def main():
    args = sys.argv[1:]
    gw = os.path.abspath(args[0])
    cape_dir = os.path.join(gw, CAPES, "CP300")
    tmpl = os.path.join(gw, CAPES, "VERILOG_TEMPLATE")
    if os.path.isdir(cape_dir):
        shutil.rmtree(cape_dir)
    shutil.copytree(tmpl, cape_dir)
    hdl = os.path.join(cape_dir, "HDL")
    os.remove(os.path.join(hdl, "apb_ctrl_status.v"))
    with open(os.path.join(hdl, "CAPE.v")) as f:
        cape = f.read()
    with open(os.path.join(hdl, "CAPE.v"), "w") as f:
        f.write(patch_cape(cape).replace("@@AXI_CONN@@", AXI_CONN))

    files = []
    for rel in SOURCES:
        src = os.path.join(REPO, rel)
        dst = os.path.join(hdl, os.path.basename(rel))
        shutil.copy(src, dst)
        if rel.endswith(".vhd"):
            strip_sim_only(dst)
        files.append(os.path.basename(rel))
    keep_in_registers(os.path.join(hdl, "wd1793.vhd"), "head_pos")
    t80 = []
    for n in T80:
        shutil.copy(os.path.join(REPO, "third_party", "T80", n + ".vhd"), os.path.join(hdl, n + ".vhd"))
        t80.append(n + ".vhd")

    # the framework imports the *.v files of the cape's HDL folder itself (MSS/scripts/hdl_source.tcl); the VHDL of
    # the core and the PLL are added here
    base = "script_support/components/CAPE/CP300/HDL/"
    with open(os.path.join(tmpl, "ADD_CAPE.tcl")) as f:
        add = f.read()
    add = add.replace("VERILOG_TEMPLATE", "CP300")
    vhdl = [n for n in t80 + files if n.endswith(".vhd")]
    imports = CCC + "".join("import_files -hdl_source {%s%s}\n" % (base, n) for n in vhdl) + "build_design_hierarchy\n\n"
    marker = "create_hdl_core -file $project_dir/hdl/CAPE.v"
    if marker not in add:
        raise SystemExit("create_hdl_core line not found in the template ADD_CAPE.tcl")
    add = add.replace(marker, imports + marker, 1)
    # the AXI4 master of the DDR probe: a BIF on the cape core, connected to FIC0's fabric-to-processor port
    bif_marker = "hdl_core_rename_bif -hdl_core_name {CAPE} -current_bif_name {BIF_1} -new_bif_name {APB_TARGET}"
    if bif_marker not in add:
        raise SystemExit("APB BIF rename line not found in the template ADD_CAPE.tcl")
    conn_marker = 'sd_connect_pins -sd_name ${sd_name} -pin_names {"CAPE:APB_TARGET" "BVF_RISCV_SUBSYSTEM:CAPE_APB_MTARGET"}'
    if conn_marker not in add:
        raise SystemExit("CAPE:APB_TARGET connection not found in the template ADD_CAPE.tcl")
    add = add.replace(conn_marker, conn_marker + "\n"
                      "sd_clear_pin_attributes -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:FIC_0_AXI4_TARGET}\n" + AXI_PINS +
                      'sd_connect_pins -sd_name ${sd_name} -pin_names {"CLOCKS_AND_RESETS:FIC_0_ACLK" "CAPE:ACLK"}\n'
                      'sd_connect_pins -sd_name ${sd_name} -pin_names {"CLOCKS_AND_RESETS:FIC_0_FABRIC_RESET_N" "CAPE:ARESETN"}', 1)
    # PREADY and PSLVERR on the APB bus interface
    add = add.replace("hdl_core_add_bif -hdl_core_name {CAPE} -bif_definition {APB:AMBA:AMBA2:slave} -bif_name {BIF_1} -signal_map {} \n",
                      "hdl_core_add_bif -hdl_core_name {CAPE} -bif_definition {APB:AMBA:AMBA2:slave} -bif_name {BIF_1} -signal_map {} \n"
                      "hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PREADY} -core_signal_name {APB_SLAVE_SLAVE_PREADY} \n"
                      "hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PSLVERR} -core_signal_name {APB_SLAVE_SLAVE_PSLVERR} \n", 1)
    with open(os.path.join(cape_dir, "ADD_CAPE.tcl"), "w") as f:
        f.write(add)

    # the template's leds.dtso stays (the stock gateware has it too); its cape overlay is replaced
    dts = os.path.join(cape_dir, "device-tree-overlays")
    os.remove(os.path.join(dts, "verilog-cape.dtso"))
    shutil.copy(os.path.join(HERE, "CAPE", "CP300", "cp300.dtso"), os.path.join(dts, "cp300.dtso"))
    print("CP300 cape written to", cape_dir)


if __name__ == "__main__":
    main()
