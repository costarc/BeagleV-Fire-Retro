library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
-- BeagleV-Fire: ht1080z with EXT_RAM, RUNTIME_ROM and EXT_CPU (the Z80 is outside, shared with the MSX1 and the Spectrum).
-- Made from syn/analogue/src/fpga/core/ht1080z_ext.vhd (Verilog cannot drive ht1080z's boolean generics).
entity ht1080z_bvf is
  port (
clk42m : in  STD_LOGIC;
        pllLocked : in  STD_LOGIC;
            reset : in  STD_LOGIC;
              led : out STD_LOGIC;
             ntsc : in  STD_LOGIC;
        ext_keys : in  std_logic_vector(63 downto 0);   
            turbo : in  STD_LOGIC;
          cass_in : in  STD_LOGIC;
         cass_out : out std_logic_vector(1 downto 0);
        xf_en : in std_logic := '0';
        xf_rst : in std_logic := '0';
        xf_ce : in std_logic := '0';
        xf_sel : in std_logic := '0';
        xf_rd : in std_logic := '0';
        xf_wr : in std_logic := '0';
        xf_addr : in std_logic_vector(1 downto 0) := "00";
        xf_din : in std_logic_vector(7 downto 0) := (others => '0');
        xf_dout : out std_logic_vector(7 downto 0);
        xf_drq : out std_logic;
        xf_intrq : out std_logic;
        xf_drive : in std_logic_vector(1 downto 0) := "00";
        xf_side : in std_logic := '0';
        xf_ready : in std_logic := '0';
        xf_wp : in std_logic := '0';
        xf_sec512 : in std_logic := '1';

         
        fdc_svc_rd : out std_logic;
        fdc_svc_wr : out std_logic;
        fdc_svc_ra : out std_logic;
     fdc_svc_track : out std_logic_vector(7 downto 0);
    fdc_svc_trkreg : out std_logic_vector(7 downto 0);
    fdc_svc_sector : out std_logic_vector(7 downto 0);
       fdc_svc_dam : out std_logic;
       fdc_svc_ack : in  std_logic;
     fdc_res_found : in  std_logic;
       fdc_res_crc : in  std_logic;
       fdc_res_dam : in  std_logic;
     fdc_buff_addr : in  std_logic_vector(8 downto 0);
     fdc_buff_dout : in  std_logic_vector(7 downto 0);
      fdc_buff_din : out std_logic_vector(7 downto 0);
       fdc_buff_wr : in  std_logic;
         fdc_drive : out std_logic_vector(1 downto 0);
          fdc_side : out std_logic;
         hd_svc : out std_logic;
         hd_flags : in  std_logic_vector(3 downto 0);
         drv_ready : in  std_logic_vector(3 downto 0);
            drv_wp : in  std_logic_vector(3 downto 0);

           ps2clk : in  STD_LOGIC;
           ps2dat : in  STD_LOGIC;

           ht_rgb : out std_logic_vector(17 downto 0);
         
       vid_screen : out std_logic;
          vid_ink : out std_logic;
         vid_pxen : out std_logic;
      vid_ink_rgb : out std_logic_vector(17 downto 0);
    vid_paper_rgb : out std_logic_vector(17 downto 0);
   vid_border_rgb : out std_logic_vector(17 downto 0);
               hs : out STD_LOGIC;
               vs : out STD_LOGIC;
               hb : out STD_LOGIC;
               vb : out STD_LOGIC;
         audiomix : out std_logic_vector(8 downto 0); 

            dn_go : in  std_logic;
            dn_wr : in  std_logic;
          dn_addr : in  std_logic_vector(24 downto 0);
          dn_data : in  std_logic_vector(7 downto 0);
           dn_idx : in  std_logic_vector(4 downto 0);

         exp_addr : out std_logic_vector(15 downto 0);
           exp_in : out std_logic;
          exp_out : out std_logic;
         exp_dout : out std_logic_vector(7 downto 0);
          exp_din : in  std_logic_vector(7 downto 0);
           exp_oe : in  std_logic;

         
         
      ext_ram_addr : out std_logic_vector(15 downto 0);
        ext_ram_rd : out std_logic;
        ext_ram_wr : out std_logic;
       ext_ram_din : out std_logic_vector(7 downto 0);
      ext_ram_dout : in  std_logic_vector(7 downto 0) ;
      ext_ram_wait : in  std_logic ;

		 
		  SDRAM_nCS : out std_logic;                     
		   SDRAM_DQ : inout std_logic_vector(15 downto 0); 
		    SDRAM_A : out std_logic_vector(12 downto 0);  
		 SDRAM_DQMH : out std_logic; 
		 SDRAM_DQML : out std_logic; 
		  SDRAM_nWE : out std_logic;  
		 SDRAM_nCAS : out std_logic; 
		 SDRAM_nRAS : out std_logic; 
		   SDRAM_BA : out std_logic_vector(1 downto 0); 
		  SDRAM_CKE : out std_logic;

           rl_clk : in  std_logic;
            rl_we : in  std_logic;
         rl_waddr : in  std_logic_vector(12 downto 0);
         rl_wdata : in  std_logic_vector(31 downto 0);
-- the shared Z80
        xcpu_reset_n : out std_logic;
        xcpu_cen     : out std_logic;
        xcpu_wait_n  : out std_logic;
        xcpu_int_n   : out std_logic;
        xcpu_nmi_n   : out std_logic;
        xcpu_di      : out std_logic_vector(7 downto 0);
        xcpu_m1_n    : in  std_logic;
        xcpu_mreq_n  : in  std_logic;
        xcpu_iorq_n  : in  std_logic;
        xcpu_rd_n    : in  std_logic;
        xcpu_wr_n    : in  std_logic;
        xcpu_a       : in  std_logic_vector(15 downto 0);
        xcpu_do      : in  std_logic_vector(7 downto 0)
);
end ht1080z_bvf;

architecture rtl of ht1080z_bvf is
begin
  u : entity work.ht1080z generic map (EXT_RAM => true, RUNTIME_ROM => true, EXT_CPU => true) port map (
    clk42m => clk42m,
    pllLocked => pllLocked,
    reset => reset,
    led => led,
    ntsc => ntsc,
    ext_keys => ext_keys,
    turbo => turbo,
    cass_in => cass_in,
    cass_out => cass_out,
    xf_en => xf_en,
    xf_rst => xf_rst,
    xf_ce => xf_ce,
    xf_sel => xf_sel,
    xf_rd => xf_rd,
    xf_wr => xf_wr,
    xf_addr => xf_addr,
    xf_din => xf_din,
    xf_dout => xf_dout,
    xf_drq => xf_drq,
    xf_intrq => xf_intrq,
    xf_drive => xf_drive,
    xf_side => xf_side,
    xf_ready => xf_ready,
    xf_wp => xf_wp,
    xf_sec512 => xf_sec512,
    fdc_svc_rd => fdc_svc_rd,
    fdc_svc_wr => fdc_svc_wr,
    fdc_svc_ra => fdc_svc_ra,
    fdc_svc_track => fdc_svc_track,
    fdc_svc_trkreg => fdc_svc_trkreg,
    fdc_svc_sector => fdc_svc_sector,
    fdc_svc_dam => fdc_svc_dam,
    fdc_svc_ack => fdc_svc_ack,
    fdc_res_found => fdc_res_found,
    fdc_res_crc => fdc_res_crc,
    fdc_res_dam => fdc_res_dam,
    fdc_buff_addr => fdc_buff_addr,
    fdc_buff_dout => fdc_buff_dout,
    fdc_buff_din => fdc_buff_din,
    fdc_buff_wr => fdc_buff_wr,
    fdc_drive => fdc_drive,
    fdc_side => fdc_side,
    hd_svc => hd_svc,
    hd_flags => hd_flags,
    drv_ready => drv_ready,
    drv_wp => drv_wp,
    ps2clk => ps2clk,
    ps2dat => ps2dat,
    ht_rgb => ht_rgb,
    vid_screen => vid_screen,
    vid_ink => vid_ink,
    vid_pxen => vid_pxen,
    vid_ink_rgb => vid_ink_rgb,
    vid_paper_rgb => vid_paper_rgb,
    vid_border_rgb => vid_border_rgb,
    hs => hs,
    vs => vs,
    hb => hb,
    vb => vb,
    audiomix => audiomix,
    dn_go => dn_go,
    dn_wr => dn_wr,
    dn_addr => dn_addr,
    dn_data => dn_data,
    dn_idx => dn_idx,
    exp_addr => exp_addr,
    exp_in => exp_in,
    exp_out => exp_out,
    exp_dout => exp_dout,
    exp_din => exp_din,
    exp_oe => exp_oe,
    ext_ram_addr => ext_ram_addr,
    ext_ram_rd => ext_ram_rd,
    ext_ram_wr => ext_ram_wr,
    ext_ram_din => ext_ram_din,
    ext_ram_dout => ext_ram_dout,
    ext_ram_wait => ext_ram_wait,
    SDRAM_nCS => SDRAM_nCS,
    SDRAM_DQ => SDRAM_DQ,
    SDRAM_A => SDRAM_A,
    SDRAM_DQMH => SDRAM_DQMH,
    SDRAM_DQML => SDRAM_DQML,
    SDRAM_nWE => SDRAM_nWE,
    SDRAM_nCAS => SDRAM_nCAS,
    SDRAM_nRAS => SDRAM_nRAS,
    SDRAM_BA => SDRAM_BA,
    SDRAM_CKE => SDRAM_CKE,
    rl_clk => rl_clk,
    rl_we => rl_we,
    rl_waddr => rl_waddr,
    rl_wdata => rl_wdata,
    xcpu_reset_n => xcpu_reset_n, xcpu_cen => xcpu_cen, xcpu_wait_n => xcpu_wait_n, xcpu_int_n => xcpu_int_n, xcpu_nmi_n => xcpu_nmi_n,
    xcpu_di => xcpu_di, xcpu_m1_n => xcpu_m1_n, xcpu_mreq_n => xcpu_mreq_n, xcpu_iorq_n => xcpu_iorq_n, xcpu_rd_n => xcpu_rd_n,
    xcpu_wr_n => xcpu_wr_n, xcpu_a => xcpu_a, xcpu_do => xcpu_do
  );
end rtl;
