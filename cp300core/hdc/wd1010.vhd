-- ====================================================================
--
--  FreeHD-compatible hard disk controller for the CP-300 (TRS-80 Model III)
--
--  The Radio Shack / FreHD hard disk interface: a WD1010 at ports C8-CF and the two
--  control registers C0 (write protect, read only) and C1 (control). What this models is what
--  the xtrs hard disk emulation (trs_hard.c) models and what the LDOS / TRSDOS / NEWDOS
--  hard disk drivers use: RESTORE, SEEK, VERIFY, READ SECTOR and WRITE SECTOR of 256-byte
--  sectors (no multi-sector, no DMA, no FORMAT TRACK: FORMAT and INIT only report done).
--
--  Like the floppy controller, this one does not know the disk image. A READ asks the IO
--  controller for the sector (cylinder, head, sector, drive), and the data comes back through
--  a 256-byte buffer; a WRITE collects the 256 bytes the Z80 sends and then asks the IO
--  controller to store them. The service handshake is the floppy controller's:
--  a request stays up until svc_ack rises; the IO controller keeps svc_ack up while it moves
--  data through the buffer and drops it when done; res_found is sampled when svc_ack falls.
--
--  Registers (C0 + n):
--    0  r: write protect, bit 7..4 = drives 0..3 (xtrs), bit 1 = some drive protected
--    1  w: control: bit 4 software reset, bit 3 enable device, bit 2 wait enable (kept, unused)
--    8  rw: data (256 bytes per sector, INIR / OTIR)
--    9  r: error   w: write precompensation (ignored)
--    A  sector count   B  sector number   C  cylinder low   D  cylinder high (bits 1:0)
--    E  size / drive / head: bits 4:3 drive, bits 2:0 head
--    F  r: status   w: command
--  Status: bit 7 busy, 6 ready, 4 seek complete, 3 data request, 0 error.
--  Error: bit 6 data error, bit 4 ID not found, bit 2 aborted.
--
--  This program is free software; you can redistribute it and/or modify it
--  under the terms of the GNU General Public License as published by the Free
--  Software Foundation; either version 2 of the License, or (at your option)
--  any later version.
--
--============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity wd1010 is
  port (
    clk_sys    : in  std_logic;
    ce         : in  std_logic;                      -- at CPU clock rate
    reset      : in  std_logic;
    io_en      : in  std_logic;                      -- C0-CF selected
    rd         : in  std_logic;                      -- i/o read (active high)
    wr         : in  std_logic;                      -- i/o write (active high)
    addr       : in  std_logic_vector(3 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);

    hd_ready   : in  std_logic_vector(1 downto 0);   -- an image is mounted in drive 0 / 1
    hd_wp      : in  std_logic_vector(1 downto 0);

    -- sector service (IO controller)
    svc_rd     : out std_logic;
    svc_wr     : out std_logic;
    svc_busy   : out std_logic;                      -- this controller owns the service, request to end of ack
    svc_cyl    : out std_logic_vector(9 downto 0);
    svc_head   : out std_logic_vector(2 downto 0);
    svc_sector : out std_logic_vector(7 downto 0);
    svc_drive  : out std_logic_vector(1 downto 0);
    svc_ack    : in  std_logic;                      -- already qualified with svc_busy
    res_found  : in  std_logic;
    svc_buff_addr : in  std_logic_vector(8 downto 0);
    svc_buff_dout : in  std_logic_vector(7 downto 0);
    svc_buff_din  : out std_logic_vector(7 downto 0);
    svc_buff_wr   : in  std_logic
  );
end wd1010;

architecture rtl of wd1010 is

  type mode_t is (M_NONE, M_READ, M_WRITE);
  signal mode : mode_t := M_NONE;

  type svc_t is (V_IDLE, V_REQ, V_ACK);
  signal svc : svc_t := V_IDLE;
  signal svc_is_wr : std_logic := '0';

  type ram_t is array (0 to 255) of std_logic_vector(7 downto 0);
  signal buff_q  : std_logic_vector(7 downto 0) := (others => '0');
  signal ptr     : unsigned(7 downto 0) := (others => '0');

  signal ctrl    : std_logic_vector(7 downto 0) := (others => '0');
  signal err     : std_logic_vector(7 downto 0) := (others => '0');
  signal seccnt  : std_logic_vector(7 downto 0) := x"01";
  signal secnum  : std_logic_vector(7 downto 0) := (others => '0');
  signal cyllo   : std_logic_vector(7 downto 0) := (others => '0');
  signal cylhi   : std_logic_vector(1 downto 0) := (others => '0');
  signal sdh     : std_logic_vector(7 downto 0) := (others => '0');
  signal status  : std_logic_vector(7 downto 0) := x"50";

  signal rde, wre : std_logic;
  signal rde_q, wre_q : std_logic := '0';       -- one CPU clock ago
  signal cur_addr : std_logic_vector(3 downto 0) := x"0";
  signal drv_ok   : std_logic;
  signal wp_reg   : std_logic_vector(7 downto 0);
  signal buff_wen : std_logic;
  signal svc_rd_r, svc_wr_r : std_logic := '0';
  signal q : std_logic_vector(7 downto 0);

  constant ST_IDLE : std_logic_vector(7 downto 0) := x"50";   -- ready, seek complete
  constant ST_DRQ  : std_logic_vector(7 downto 0) := x"58";
  constant ST_BUSY : std_logic_vector(7 downto 0) := x"D0";
  constant ST_ERR  : std_logic_vector(7 downto 0) := x"51";

begin

  rde <= rd and io_en;
  wre <= wr and io_en;
  drv_ok <= '1' when sdh(4) = '0' and hd_ready(to_integer(unsigned(sdh(3 downto 3)))) = '1' else '0';

  svc_rd <= svc_rd_r;
  svc_wr <= svc_wr_r;
  svc_busy <= '1' when svc /= V_IDLE else '0';
  svc_cyl    <= cylhi & cyllo;
  svc_head   <= sdh(2 downto 0);
  svc_sector <= secnum;
  svc_drive  <= '0' & sdh(3);

  wp_reg <= (hd_wp(0) and hd_ready(0)) & (hd_wp(1) and hd_ready(1)) & "000000";
  -- the data byte of an OUT is stored when the cycle starts (the data is on the bus then)
  buff_wen <= '1' when wre = '1' and wre_q = '0' and mode = M_WRITE and addr = x"8" else '0';
  svc_buff_din <= buff_q;

  -- The data buffer is one single-port RAM. The IO controller owns it while it acknowledges a
  -- request; the controller never touches it then.
  process(clk_sys)
    variable ram : ram_t;
    variable a   : integer;
    variable we  : std_logic;
    variable d   : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_sys) then
      if svc_ack = '1' then
        a := to_integer(unsigned(svc_buff_addr(7 downto 0))); we := svc_buff_wr; d := svc_buff_dout;
      else
        a := to_integer(ptr); we := buff_wen; d := din;
      end if;
      if we = '1' then
        ram(a) := d;
        buff_q <= d;
      else
        buff_q <= ram(a);
      end if;
    end if;
  end process;

  process(addr, buff_q, err, seccnt, secnum, cyllo, cylhi, sdh, status, ctrl, wp_reg)
    variable any_wp : std_logic;
  begin
    any_wp := wp_reg(7) or wp_reg(6);
    case addr is
      when x"0"   => q <= wp_reg(7) & wp_reg(6) & "0000" & any_wp & '0';
      when x"1"   => q <= ctrl;
      when x"8"   => q <= buff_q;
      when x"9"   => q <= err;
      when x"A"   => q <= seccnt;
      when x"B"   => q <= secnum;
      when x"C"   => q <= cyllo;
      when x"D"   => q <= "000000" & cylhi;
      when x"E"   => q <= sdh;
      when x"F"   => q <= status;
      when others => q <= x"FF";
    end case;
  end process;
  dout <= q;

  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if reset = '1' then
        mode <= M_NONE; svc <= V_IDLE; svc_rd_r <= '0'; svc_wr_r <= '0';
        ptr <= (others => '0'); ctrl <= (others => '0'); err <= (others => '0');
        seccnt <= x"01"; secnum <= (others => '0'); cyllo <= (others => '0'); cylhi <= (others => '0');
        sdh <= (others => '0'); status <= ST_IDLE;
      else

        -- service handshake (every clock: the acknowledge of a sector that is not found is short)
        case svc is
          when V_IDLE => null;
          when V_REQ =>
            if svc_ack = '1' then
              svc_rd_r <= '0'; svc_wr_r <= '0';
              svc <= V_ACK;
            end if;
          when V_ACK =>
            if svc_ack = '0' then
              svc <= V_IDLE;
              if svc_is_wr = '1' then
                mode <= M_NONE;
                if res_found = '1' then status <= ST_IDLE;
                else status <= ST_ERR; err <= x"40"; end if;
              else
                if res_found = '1' then
                  mode <= M_READ; ptr <= (others => '0'); status <= ST_DRQ;
                else
                  mode <= M_NONE; status <= ST_ERR; err <= x"10";
                end if;
              end if;
            end if;
        end case;

        if ce = '1' then
          rde_q <= rde;
          wre_q <= wre;
          if rde = '1' and rde_q = '0' then cur_addr <= addr; end if;
          -- data register read: the next byte once the cycle is over (the Z80 has taken this one)
          if rde = '0' and rde_q = '1' and cur_addr = x"8" and mode = M_READ then
            ptr <= ptr + 1;
            if ptr = 255 then mode <= M_NONE; status <= ST_IDLE; end if;
          end if;
          if buff_wen = '1' then
            ptr <= ptr + 1;
            if ptr = 255 then
              mode <= M_NONE;
              status <= ST_BUSY;
              svc_is_wr <= '1'; svc_wr_r <= '1'; svc <= V_REQ;
            end if;
          end if;

          if wre = '1' and wre_q = '0' then
            case addr is
              when x"1" =>
                ctrl <= din;
                if din(4) = '1' then                 -- software reset
                  mode <= M_NONE; err <= (others => '0'); status <= ST_IDLE;
                end if;
              when x"A" => seccnt <= din;
              when x"B" => secnum <= din;
              when x"C" => cyllo <= din;
              when x"D" => cylhi <= din(1 downto 0);
              when x"E" => sdh <= din; status <= ST_IDLE; mode <= M_NONE;
              when x"F" =>
                if svc = V_IDLE then
                  mode <= M_NONE;
                  case din(7 downto 4) is
                    when x"1" => cyllo <= (others => '0'); cylhi <= "00"; status <= ST_IDLE;
                    when x"2" | x"3" =>
                      if din(2) = '1' then                    -- multi-sector: not supported
                        status <= ST_ERR; err <= x"04";
                      elsif drv_ok = '0' then
                        status <= ST_ERR; err <= x"10";
                      elsif din(5 downto 4) = "11" and hd_wp(to_integer(unsigned(sdh(3 downto 3)))) = '1' then
                        status <= ST_ERR; err <= x"40";       -- write to a protected image
                      elsif din(5 downto 4) = "10" then       -- 2x read
                        status <= ST_BUSY;
                        svc_is_wr <= '0'; svc_rd_r <= '1'; svc <= V_REQ;
                      else                                    -- 3x write: the data comes first
                        ptr <= (others => '0'); mode <= M_WRITE; status <= ST_DRQ;
                      end if;
                    when x"4" | x"7" =>
                      if drv_ok = '1' then status <= ST_IDLE; else status <= ST_ERR; err <= x"10"; end if;
                    when x"5" | x"6" => status <= ST_IDLE;
                    when others => null;
                  end case;
                end if;
              when others => null;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;

end rtl;
