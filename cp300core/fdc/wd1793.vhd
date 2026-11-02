-- ====================================================================
--
--  WD1793 replica for the CP-300 (TRS-80 Model III floppy controller)
--
--  VHDL port, trimmed to what the Model III needs, of the WD1793/WD1772
--  replica (with write capability) by
--    Copyright (C) 2007,2008 Viacheslav Slavinsky
--    Copyright (C) 2016 Sorgelig
--    Modifications for track size of 18 x 256 by Stan Hodge (SRH) 9/6/21
--  as used in the CoCo2_FPGA / MiSTer cores.
--
--  Changes for this project: VHDL, 256-byte sectors, the head position is kept
--  per drive, no WRITE TRACK / READ TRACK. The controller does not know the
--  disk image format: it asks the IO controller for a sector (head position,
--  track register for the ID match, sector number, side) and gets back found /
--  CRC error / deleted mark; the sector data and the READ ADDRESS bytes travel
--  through the 512-byte buffer here. The IO controller reads DMK images.
--
--  This program is free software; you can redistribute it and/or modify it
--  under the terms of the GNU General Public License as published by the Free
--  Software Foundation; either version 2 of the License, or (at your option)
--  any later version.
--
--  This program is distributed in the hope that it will be useful, but WITHOUT
--  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
--  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
--  more details.
--
--============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity wd1793 is
  port (
    clk_sys    : in  std_logic;
    ce         : in  std_logic;                      -- at CPU clock rate
    reset      : in  std_logic;
    io_en      : in  std_logic;                      -- F0-F3 selected
    rd         : in  std_logic;                      -- i/o read (active high)
    wr         : in  std_logic;                      -- i/o write (active high)
    addr       : in  std_logic_vector(1 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);
    drq        : out std_logic;
    intrq      : out std_logic;
    busy       : out std_logic;

    -- selected drive
    drive      : in  std_logic_vector(1 downto 0);
    side       : in  std_logic;
    ready      : in  std_logic;
    wp         : in  std_logic;
    sec512     : in  std_logic := '0';               -- 1: 512-byte sectors (MSX disks), 0: 256 bytes (TRS-80)

    -- sector service (IO controller): a request stays up until svc_ack rises; the IO controller
    -- keeps svc_ack up while it moves data through the buffer and drops it when done
    svc_rd     : out std_logic;                      -- find the sector, put its data in the buffer
    svc_wr     : out std_logic;                      -- store the buffer in the sector
    svc_ra     : out std_logic;                      -- next ID field of the track into buffer bytes 0-5
    svc_track  : out std_logic_vector(7 downto 0);   -- head position of the drive
    svc_trkreg : out std_logic_vector(7 downto 0);   -- track register (must match the ID field)
    svc_sector : out std_logic_vector(7 downto 0);
    svc_dam    : out std_logic;                      -- write: 1 = deleted data mark
    svc_ack    : in  std_logic;
    res_found  : in  std_logic;                      -- sampled when svc_ack falls
    res_crc    : in  std_logic;                      -- CRC error in the sector
    res_dam    : in  std_logic;                      -- the sector has a deleted data mark
    svc_buff_addr : in  std_logic_vector(8 downto 0);
    svc_buff_dout : in  std_logic_vector(7 downto 0);
    svc_buff_din  : out std_logic_vector(7 downto 0);
    svc_buff_wr   : in  std_logic
  );
end wd1793;

architecture rtl of wd1793 is

  type state_t is (S_IDLE, S_SEARCH, S_WAIT_READ, S_WAIT_READ_1, S_WAIT_READ_2,
                   S_WAIT_RA_1, S_WAIT_RA_2,
                   S_READ, S_READ_1, S_READ_2,
                   S_WAIT_WRITE, S_WAIT_WRITE_1, S_WAIT_WRITE_2,
                   S_WRITE, S_WRITE_1, S_WRITE_2,
                   S_ABORT, S_WAIT, S_WAIT_2, S_ENDCOMMAND);
  signal state : state_t := S_IDLE;

  -- sector buffer: one 512-byte block
  type ram_t is array (0 to 511) of std_logic_vector(7 downto 0);
  signal buff_q    : std_logic_vector(7 downto 0) := (others => '0');
  signal buff_wen  : std_logic;

  signal byte_addr : unsigned(8 downto 0) := (others => '0');
  signal data_length : unsigned(9 downto 0) := (others => '0');

  type head_t is array (0 to 3) of unsigned(7 downto 0);
  signal head_pos   : head_t := (others => (others => '0'));
  signal disk_track : unsigned(7 downto 0) := (others => '0');   -- head position of the selected drive
  signal drive_r    : std_logic_vector(1 downto 0) := "00";

  signal s_readonly : std_logic;
  signal s_crcerr, s_headloaded, s_seekerr, s_index : std_logic := '0';
  signal s_lostdata, s_wrfault : std_logic := '0';       -- s_wrfault doubles as "record type" after a read
  signal cmd_mode : std_logic := '0';
  signal s_wpe    : std_logic := '1';
  signal s_drq_busy : std_logic_vector(1 downto 0) := "00";
  signal s_drq  : std_logic;
  signal s_busy : std_logic;
  signal s_intrq : std_logic := '0';

  signal wdreg_track  : unsigned(7 downto 0) := (others => '0');
  signal wdreg_sector : unsigned(7 downto 0) := (others => '0');
  signal wdreg_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal wdreg_status : std_logic_vector(7 downto 0);
  signal q : std_logic_vector(7 downto 0);

  signal buff_rd   : std_logic := '0';
  signal buff_wr   : std_logic := '0';
  signal step_direction : std_logic := '0';

  signal r_found, r_crc, r_dam : std_logic := '0';   -- result of the last request
  signal dam_sel : std_logic := '0';

  signal watchdog_set : std_logic := '0';
  signal wd_timer : unsigned(15 downto 0) := (others => '0');
  signal watchdog_bark : std_logic;

  signal idx_cnt : integer range 0 to 31822 := 0;

  signal rde, wre : std_logic;
  signal trk0 : std_logic;
  signal old_wr, old_rd : std_logic := '0';
  signal cur_addr : std_logic_vector(1 downto 0) := "00";
  signal read_data, write_data : std_logic := '0';
  signal rw_type, multisector, write_cmd : std_logic := '0';
  signal wait_time : integer range 0 to 4095 := 0;
  signal read_timer : unsigned(3 downto 0) := (others => '0');
  signal seektimer  : unsigned(9 downto 0) := (others => '1');
  signal ack : std_logic_vector(5 downto 0) := (others => '0');
  signal sd_busy : std_logic := '0';
  signal svc_rd_r, svc_wr_r, svc_ra_r : std_logic := '0';

  signal next_track : unsigned(7 downto 0);
  signal next_length : unsigned(9 downto 0);

begin

  dout  <= q;
  drq   <= s_drq;
  intrq <= s_intrq;
  busy  <= s_busy;
  s_drq  <= s_drq_busy(1);
  s_busy <= s_drq_busy(0);
  svc_rd <= svc_rd_r;
  svc_wr <= svc_wr_r;
  svc_ra <= svc_ra_r;
  svc_track  <= std_logic_vector(disk_track);
  svc_trkreg <= std_logic_vector(wdreg_track);
  svc_sector <= std_logic_vector(wdreg_sector);
  svc_dam    <= dam_sel;
  s_readonly <= wp;
  rde <= rd and io_en;
  wre <= wr and io_en;
  watchdog_bark <= '1' when wd_timer = 0 else '0';
  next_length <= data_length - 1;
  svc_buff_din <= buff_q;

  buff_wen <= '1' when wre = '1' and buff_wr = '1' and addr = "11" else '0';
  trk0 <= '1' when disk_track = 0 else '0';

  -- The sector buffer is one single-port RAM. The IO controller owns it while it acknowledges
  -- a request (svc_ack); the FDC never touches it then.
  process(clk_sys)
    variable ram : ram_t;
    variable a   : integer;
    variable we  : std_logic;
    variable d   : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_sys) then
      if svc_ack = '1' then
        a := to_integer(unsigned(svc_buff_addr)); we := svc_buff_wr; d := svc_buff_dout;
      else
        a := to_integer(byte_addr); we := buff_wen; d := din;
      end if;
      if we = '1' then
        ram(a) := d;
        buff_q <= d;
      else
        buff_q <= ram(a);
      end if;
    end if;
  end process;

  with cmd_mode select wdreg_status <=
    (not ready) & (s_readonly and s_wpe) & s_headloaded & (s_seekerr or not ready) &
      s_crcerr & trk0 & s_index & s_busy when '0',
    (not ready) & (s_readonly and s_wpe) & s_wrfault & (s_seekerr or not ready) &
      s_crcerr & s_lostdata & s_drq & s_busy when others;

  process(addr, wdreg_status, wdreg_track, wdreg_sector, wdreg_data, state, buff_rd, buff_q)
  begin
    case addr is
      when "00" => q <= wdreg_status;
      when "01" => q <= std_logic_vector(wdreg_track);
      when "10" => q <= std_logic_vector(wdreg_sector);
      when others =>
        if state = S_IDLE then q <= wdreg_data;
        elsif buff_rd = '1' then q <= buff_q;
        else q <= x"00";
        end if;
    end case;
  end process;

  next_track <= disk_track - 1 when ((din(6) = '1' and din(5) = '1') or (din(6) = '0' and step_direction = '1'))
                else disk_track + 1;

  -- watchdog (lost data) and index pulse
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if ce = '1' then
        if watchdog_set = '1' then wd_timer <= to_unsigned(4096, 16);
        elsif wd_timer /= 0 then wd_timer <= wd_timer - 1; end if;

        if ready = '1' then
          if idx_cnt /= 0 then idx_cnt <= idx_cnt - 1; else idx_cnt <= 31822; end if;
        else
          idx_cnt <= 0;
        end if;
        -- no index pulses without a disk turning (the ROM relies on that to give up and ask "Cass?")
        if ready = '1' and idx_cnt < 100 then s_index <= '1'; else s_index <= '0'; end if;
      end if;
    end if;
  end process;

  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if reset = '1' then
        read_data <= '0'; write_data <= '0'; multisector <= '0'; step_direction <= '0';
        disk_track <= (others => '0'); head_pos <= (others => (others => '0'));
        wdreg_track <= (others => '0'); wdreg_sector <= (others => '0'); wdreg_data <= (others => '0');
        data_length <= (others => '0'); byte_addr <= (others => '0');
        buff_rd <= '0'; buff_wr <= '0'; state <= S_IDLE; cmd_mode <= '0'; s_wpe <= '1';
        s_headloaded <= '0'; s_seekerr <= '0'; s_crcerr <= '0'; s_intrq <= '0';
        s_wrfault <= '0'; s_lostdata <= '0'; s_drq_busy <= "00"; watchdog_set <= '0';
        seektimer <= (others => '1'); ack <= (others => '0');
        sd_busy <= '0'; drive_r <= drive;
        svc_rd_r <= '0'; svc_wr_r <= '0'; svc_ra_r <= '0'; r_found <= '0'; r_crc <= '0'; r_dam <= '0';
      elsif ce = '1' then

        -- the head stays where it is when another drive is selected
        if drive /= drive_r and state = S_IDLE then
          head_pos(to_integer(unsigned(drive_r))) <= disk_track;
          disk_track <= head_pos(to_integer(unsigned(drive)));
          drive_r <= drive;
        end if;

        ack <= ack(4 downto 0) & svc_ack;
        if ack(5 downto 4) = "01" then svc_rd_r <= '0'; svc_wr_r <= '0'; svc_ra_r <= '0'; end if;
        if ack(5 downto 4) = "10" then
          sd_busy <= '0';
          r_found <= res_found; r_crc <= res_crc; r_dam <= res_dam;
        end if;

        old_wr <= wre;
        old_rd <= rde;
        if (old_rd = '0' and rde = '1') or (old_wr = '0' and wre = '1') then cur_addr <= addr; end if;

        -- reading the status register clears INTRQ
        if old_rd = '1' and rde = '0' and cur_addr = "00" then s_intrq <= '0'; end if;
        -- end of data reading / writing
        if old_rd = '1' and rde = '0' and cur_addr = "11" then read_data <= '1'; end if;
        if old_wr = '1' and wre = '0' and cur_addr = "11" then write_data <= '1'; end if;

        case state is
          when S_IDLE => null;

          when S_SEARCH =>
            if ready = '0' then
              s_seekerr <= '1';
              state <= S_ENDCOMMAND;
            else
              seektimer <= seektimer - 1;
              if seektimer = 0 then
                byte_addr <= (others => '0');
                if rw_type = '1' then
                  state <= S_WAIT_READ;
                else
                  state <= S_WAIT_RA_1;
                end if;
              end if;
            end if;

          -- find the sector and load it (also before a write: that is the record-not-found check)
          when S_WAIT_READ =>
            if sec512 = '1' then data_length <= to_unsigned(512, 10); else data_length <= to_unsigned(256, 10); end if;
            byte_addr <= (others => '0');
            state <= S_WAIT_READ_1;
          when S_WAIT_READ_1 =>
            sd_busy <= '1';
            svc_rd_r <= '1';
            state <= S_WAIT_READ_2;
          when S_WAIT_READ_2 =>
            if sd_busy = '0' then
              if r_found = '0' then
                s_seekerr <= '1';
                state <= S_ENDCOMMAND;
              else
                s_crcerr <= r_crc;
                if write_cmd = '1' then
                  state <= S_WRITE;
                else
                  s_wrfault <= r_dam;               -- status bit 5: record type
                  state <= S_READ;
                end if;
              end if;
            end if;

          -- READ ADDRESS: the next ID field of the track
          when S_WAIT_RA_1 =>
            sd_busy <= '1';
            svc_ra_r <= '1';
            state <= S_WAIT_RA_2;
          when S_WAIT_RA_2 =>
            if sd_busy = '0' then
              if r_found = '0' then
                s_seekerr <= '1';
                state <= S_ENDCOMMAND;
              else
                data_length <= to_unsigned(6, 10);
                byte_addr <= (others => '0');
                buff_rd <= '1';
                state <= S_READ;
              end if;
            end if;

          when S_READ =>
            watchdog_set <= '1';
            read_timer <= to_unsigned(15, 4);
            state <= S_READ_1;
          when S_READ_1 =>
            read_timer <= read_timer - 1;
            if read_timer = 0 then
              read_data <= '0';
              watchdog_set <= '0';
              s_lostdata <= '0';
              s_drq_busy <= "11";
              state <= S_READ_2;
            end if;
          when S_READ_2 =>
            if watchdog_bark = '1' or (read_data = '1' and s_drq = '1') then
              s_drq_busy <= "01";
              s_lostdata <= watchdog_bark;
              if next_length = 0 then
                if multisector = '1' then
                  wdreg_sector <= wdreg_sector + 1;
                  state <= S_SEARCH;
                else
                  state <= S_ENDCOMMAND;
                end if;
              else
                byte_addr <= byte_addr + 1;
                data_length <= next_length;
                state <= S_READ;
              end if;
            end if;

          when S_WAIT_WRITE =>
            if ready = '0' then
              s_wrfault <= '1';
              state <= S_ENDCOMMAND;
            else
              state <= S_WAIT_WRITE_1;
            end if;
          when S_WAIT_WRITE_1 =>
            sd_busy <= '1';
            svc_wr_r <= '1';
            state <= S_WAIT_WRITE_2;
          when S_WAIT_WRITE_2 =>
            if sd_busy = '0' then
              if r_found = '0' then
                s_wrfault <= '1';
                state <= S_ENDCOMMAND;
              elsif multisector = '1' then
                wdreg_sector <= wdreg_sector + 1;
                state <= S_SEARCH;
              else
                state <= S_ENDCOMMAND;
              end if;
            end if;

          when S_WRITE =>
            watchdog_set <= '1';
            read_timer <= to_unsigned(15, 4);
            state <= S_WRITE_1;
          when S_WRITE_1 =>
            read_timer <= read_timer - 1;
            if read_timer = 0 then
              write_data <= '0';
              watchdog_set <= '0';
              s_lostdata <= '0';
              s_drq_busy <= "11";
              state <= S_WRITE_2;
            end if;
          when S_WRITE_2 =>
            if watchdog_bark = '1' or (write_data = '1' and s_drq = '1') then
              s_drq_busy <= "01";
              s_lostdata <= watchdog_bark;
              if next_length = 0 then
                state <= S_WAIT_WRITE;
              else
                byte_addr <= byte_addr + 1;
                data_length <= next_length;
                state <= S_WRITE;
              end if;
            end if;

          when S_ABORT =>
            data_length <= (others => '0');
            s_wrfault <= '0'; s_seekerr <= '0'; s_crcerr <= '0'; s_lostdata <= '0';
            state <= S_ENDCOMMAND;

          when S_WAIT =>
            wait_time <= 4000;
            state <= S_WAIT_2;
          when S_WAIT_2 =>
            if wait_time /= 0 then wait_time <= wait_time - 1;
            else state <= S_ENDCOMMAND; end if;

          when S_ENDCOMMAND =>
            buff_rd <= '0';
            buff_wr <= '0';
            state <= S_IDLE;
            s_drq_busy <= "00";
            seektimer <= (others => '1');
            s_intrq <= '1';
        end case;

        -- register writes
        if old_wr = '0' and wre = '1' then
          case addr is
            when "00" =>
              s_intrq <= '0';
              if state = S_IDLE or din(7 downto 4) = x"D" then
                cmd_mode <= din(7);
                s_wpe <= not din(7);
                case din(7 downto 4) is
                  when x"0" =>                         -- RESTORE
                    s_headloaded <= din(3);
                    wdreg_track <= (others => '0');
                    disk_track <= (others => '0');
                    s_drq_busy <= "01";
                    state <= S_WAIT;
                  when x"1" =>                         -- SEEK
                    disk_track <= unsigned(wdreg_data);
                    s_headloaded <= din(3);
                    wdreg_track <= unsigned(wdreg_data);
                    s_drq_busy <= "01";
                    state <= S_WAIT;
                  when x"2" | x"3" | x"4" | x"5" | x"6" | x"7" =>   -- STEP, STEP-IN, STEP-OUT
                    if din(6) = '1' then step_direction <= din(5); end if;
                    disk_track <= next_track;
                    if din(4) = '1' then wdreg_track <= next_track; end if;
                    s_headloaded <= din(3);
                    s_drq_busy <= "01";
                    state <= S_WAIT;
                  when x"8" | x"9" | x"A" | x"B" =>   -- READ / WRITE SECTOR
                    s_drq_busy <= "01";
                    s_wrfault <= '0'; s_seekerr <= '0'; s_crcerr <= '0'; s_lostdata <= '0';
                    write_cmd <= din(5);
                    dam_sel <= din(0);
                    buff_rd <= not din(5);
                    buff_wr <= din(5);
                    multisector <= din(4);
                    rw_type <= '1';
                    write_data <= '0';
                    read_data <= '0';
                    s_wpe <= din(5);
                    state <= S_SEARCH;
                    if s_readonly = '1' and din(5) = '1' then
                      s_wrfault <= '1';
                      state <= S_WAIT;
                    end if;
                  when x"C" =>                         -- READ ADDRESS
                    s_drq_busy <= "01";
                    s_wrfault <= '0'; s_seekerr <= '0'; s_crcerr <= '0'; s_lostdata <= '0';
                    write_cmd <= '0';
                    buff_rd <= '0';
                    buff_wr <= '0';
                    multisector <= '0';
                    rw_type <= '0';
                    read_data <= '0';
                    state <= S_SEARCH;
                  when x"D" =>                         -- FORCE INTERRUPT
                    cmd_mode <= '0';
                    if state /= S_IDLE then
                      state <= S_ABORT;
                    else
                      s_wrfault <= '0'; s_seekerr <= '0'; s_crcerr <= '0'; s_lostdata <= '0';
                      s_drq_busy <= "00";
                    end if;
                  when x"F" =>                         -- WRITE TRACK (not supported)
                    s_wpe <= din(5);
                    s_wrfault <= '0'; s_seekerr <= '0'; s_crcerr <= '0'; s_lostdata <= '0';
                    s_drq_busy <= "01";
                    state <= S_WAIT;
                  when others =>                       -- READ TRACK (not supported)
                    s_wrfault <= '0'; s_crcerr <= '0'; s_lostdata <= '0';
                    s_seekerr <= '1';
                    s_drq_busy <= "01";
                    state <= S_WAIT;
                end case;
              end if;
            when "01" =>
              if s_busy = '0' then wdreg_track <= unsigned(din); end if;
            when "10" =>
              if s_busy = '0' then wdreg_sector <= unsigned(din); end if;
            when others =>
              wdreg_data <= din;
          end case;
        end if;
      end if;
    end if;
  end process;

end rtl;
