--------------------------------------------------------------------------------
-- MEGA65 audio into the Zynq UltraScale+ DisplayPort live-audio input.
--
-- The KV260 carrier brings out no audio hardware -- the core's PWM outputs land
-- on PMOD pins with nothing attached -- so sound leaves the board the same way
-- the picture does: embedded in the DisplayPort stream, out over HDMI to the
-- TV.  The PS exposes that as an AXI4-Stream slave (dp_s_axis_audio_*), and
-- this block is the stream master feeding it.
--
-- HOW THE PS SIDE HAS TO BE SEQUENCED
--
-- The DisplayPort audio engine only runs while ALSA has a PCM stream open.
-- With no stream the engine is down, m_axis_tready never asserts, and this
-- block stalls forever -- which looks exactly like a broken stream master and
-- cost a long time to diagnose.  So the PS must:
--
--   1. hold a stream open on the *other* PCM device (hw:0,1), which keeps the
--      engine alive without contending for the live path, and
--   2. only then point AV_BUF_OUTPUT.AUD1 at the live input.
--
-- Done in that order, live video and live audio coexist happily.  Done the
-- other way round the engine never starts.  See tools/m65audio.sh.
--
-- WHY THE FORMAT IS A RUNTIME REGISTER AND NOT A CONSTANT
--
-- How a sample must be justified inside the 32-bit beat, and what tid means,
-- are things I could only confirm from documentation I could not reach.  Baking
-- in a guess would make each wrong guess cost a full re-synthesis.  So the
-- placement shift, the channel-id polarity and the sample rate are all
-- registers: if the first attempt sounds wrong, it is fixed with a poke from
-- Linux rather than an hour of Vivado.  This is the same approach that got the
-- video path working -- switch it live, look at the result, adjust.
--
-- Register map (AXI4-Lite):
--   0x00  RW  CTRL   [0]     enable
--                    [1]     swap channels (send right first / invert tid)
--                    [2]     mute (stream keeps running, samples forced to 0,
--                            so the sink stays locked)
--                    [7:4]   sample placement: left-shift of the sign-extended
--                            20-bit sample within the 32-bit beat.
--                            4  => 24-bit sample sitting in tdata[23:0]
--                            12 => 24-bit sample sitting in tdata[31:8]
--   0x04  RW  DIV    frame rate divisor; frame rate = aud_clk / (DIV+1).
--                    Default 511 => 24.576 MHz / 512 = exactly 48 kHz.
--   0x08  R   MAGIC  0x4D363541 ("M65A") for probing
--   0x0C  R   STAT   [15:0]  frames sent (wraps)
--                    [31:16] beats the sink was not ready for (backpressure)
--   0x10  R   DROPS  [15:0]  FIFO overflows (saturating)
--                    [31:16] source captures missed (saturating)
--   0x14  R   FIFO   [15:0]  current queued stereo frames
--                    [31:16] maximum queued frames since reset
--   0x18  R   STALL  [15:0]  longest consecutive backpressure run in clocks
--                    [31:16] configured FIFO depth
--   0x1C  R   CAP    0x41554631 ("AUF1": audio FIFO diagnostics v1)
--
-- CLOCKING -- and a mistake worth recording.
--
-- The first version ran the stream on pl_clk0 (100 MHz) to avoid depending on
-- dp_audio_ref_clk, whose rate I did not know.  That is not allowed: the PS8
-- pin DPSAXISAUDIOCLK has a minimum period of 40 ns, so 25 MHz is a hard
-- ceiling, and the build reported "Min Period ... Required 40.000 Actual
-- 10.000, slack -30.000".  Avoiding an unknown by inventing a constraint of my
-- own was the wrong trade.
--
-- So the stream now runs on dp_audio_ref_clk (24 MHz in the static PS preset),
-- which is what
-- that output exists for, buffered onto a global clock and handed back to the
-- PS so both ends of the stream share one clock.  The AXI-Lite registers stay
-- on pl_clk0 because that is the interconnect's clock; the handful of config
-- values cross into the audio domain, and they only change when a human pokes
-- them.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity dp_audio_axis is
  generic (
    -- 4096 stereo frames absorb more than 85 ms at 48 kHz.  The normal path
    -- stays near empty, so this adds resilience without adding steady-state
    -- latency.  A generic keeps the bounded simulation small and fast.
    FIFO_DEPTH_G : positive := 4096
  );
  port (
    -- AXI4-Lite control, on the interconnect's clock
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;

    -- dp_audio_ref_clk straight from the PS, and the same clock after a global
    -- buffer.  aud_clk_out goes back to the PS as dp_s_axis_audio_clk so the
    -- stream master and slave are genuinely the same clock.
    aud_clk_in  : in  std_logic;
    aud_clk_out : out std_logic;

    s_axi_awaddr  : in  std_logic_vector(4 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;

    s_axi_araddr  : in  std_logic_vector(4 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- Audio from the core, in the core's own clock domain
    core_clk    : in std_logic;
    audio_left  : in std_logic_vector(19 downto 0);
    audio_right : in std_logic_vector(19 downto 0);

    -- To the PS DisplayPort live-audio input
    m_axis_tdata  : out std_logic_vector(31 downto 0) := (others => '0');
    m_axis_tid    : out std_logic_vector(0 downto 0)  := "0";
    m_axis_tvalid : out std_logic := '0';
    m_axis_tready : in  std_logic
  );

  -- Associate the generated module-reference clock with its AXI-stream bus.
  -- Keep port attributes in the entity's scope: Vivado accepted them in the
  -- architecture, but that placement is non-standard and GHDL rejects it.
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aud_clk_in : signal is
    "xilinx.com:signal:clock:1.0 aud_clk_in CLK";
  attribute X_INTERFACE_PARAMETER of aud_clk_in : signal is
    "XIL_INTERFACENAME aud_clk_in, FREQ_HZ 24000000, PHASE 0.0";
  attribute X_INTERFACE_INFO of aud_clk_out : signal is
    "xilinx.com:signal:clock:1.0 aud_clk_out CLK";
  attribute X_INTERFACE_PARAMETER of aud_clk_out : signal is
    "XIL_INTERFACENAME aud_clk_out, ASSOCIATED_BUSIF M_AXIS, FREQ_HZ 24000000, PHASE 0.0";
end dp_audio_axis;

architecture rtl of dp_audio_axis is

  -- dp_audio_ref_clk measured on the board is 24,575,995 Hz -- that is 24.576
  -- MHz, the canonical 512*48000 audio master clock.  (Vivado's board preset
  -- reports 24 MHz for this output; the driver reprograms it, so trust the
  -- hardware, not the preset.)  Dividing by 512 therefore lands exactly on
  -- 48 kHz with no error at all.
  constant DIV_DEFAULT : natural := 511;

  signal aud_clk : std_logic;
  signal aud_reset_pipe : std_logic_vector(1 downto 0) := (others => '0');
  signal aud_resetn : std_logic := '0';

  -- Config values as seen in the audio domain.  They are written by a human
  -- via AXI and then sit still, so a two-flop sync per bit is honest here:
  -- there is no instant at which a coherent multi-bit update matters.
  signal ctrl_meta : std_logic_vector(7 downto 0) := x"40";
  signal ctrl_aud  : std_logic_vector(7 downto 0) := x"40";
  signal div_meta  : unsigned(15 downto 0) := to_unsigned(DIV_DEFAULT, 16);
  signal div_aud   : unsigned(15 downto 0) := to_unsigned(DIV_DEFAULT, 16);

  -- Diagnostic counters travelling the other way.  Approximate by construction:
  -- they may read torn if sampled mid-increment, which for a frame counter
  -- ticking at 48 kHz is not worth a handshake.
  signal frames_meta : unsigned(15 downto 0) := (others => '0');
  signal frames_sync : unsigned(15 downto 0) := (others => '0');
  signal stalls_meta : unsigned(15 downto 0) := (others => '0');
  signal stalls_sync : unsigned(15 downto 0) := (others => '0');
  signal overflows_meta : unsigned(15 downto 0) := (others => '0');
  signal overflows_sync : unsigned(15 downto 0) := (others => '0');
  signal misses_meta : unsigned(15 downto 0) := (others => '0');
  signal misses_sync : unsigned(15 downto 0) := (others => '0');
  signal fifo_level_meta : unsigned(15 downto 0) := (others => '0');
  signal fifo_level_sync : unsigned(15 downto 0) := (others => '0');
  signal fifo_high_meta : unsigned(15 downto 0) := (others => '0');
  signal fifo_high_sync : unsigned(15 downto 0) := (others => '0');
  signal max_stall_meta : unsigned(15 downto 0) := (others => '0');
  signal max_stall_sync : unsigned(15 downto 0) := (others => '0');

  signal ctrl_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal div_reg  : unsigned(15 downto 0) := to_unsigned(DIV_DEFAULT, 16);

  alias  en_bit    : std_logic is ctrl_aud(0);
  alias  swap_bit  : std_logic is ctrl_aud(1);
  alias  mute_bit  : std_logic is ctrl_aud(2);
  signal shift_amt : integer range 0 to 15 := 4;

  signal awready_i : std_logic := '0';
  signal wready_i  : std_logic := '0';
  signal bvalid_i  : std_logic := '0';
  signal arready_i : std_logic := '0';
  signal rvalid_i  : std_logic := '0';
  signal rdata_i   : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_addr   : std_logic_vector(4 downto 0) := (others => '0');
  signal wr_data   : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_strb   : std_logic_vector(3 downto 0) := (others => '0');
  signal aw_held   : std_logic := '0';
  signal w_held    : std_logic := '0';

  -- Sample-rate divider.  Capture requests continue at exactly the configured
  -- rate even while the sink applies backpressure; the FIFO decouples those
  -- two events instead of silently skipping a sample.
  signal rate_cnt : unsigned(15 downto 0) := (others => '0');

  ------------------------------------------------------------------------------
  -- Clock crossing, destination-driven.
  --
  -- The stream side asks for a sample by toggling req; the core side sees the
  -- toggle, latches both channels at one instant (so left and right are always
  -- from the same moment) and toggles ack.  Between the ack and the next req
  -- the captured pair is guaranteed not to move, so the stream side can write
  -- it safely into the local FIFO.
  ------------------------------------------------------------------------------
  signal req_tog     : std_logic := '0';
  signal req_sync    : std_logic_vector(2 downto 0) := (others => '0');
  signal ack_tog     : std_logic := '0';
  signal ack_sync    : std_logic_vector(2 downto 0) := (others => '0');
  signal cap_l       : std_logic_vector(19 downto 0) := (others => '0');
  signal cap_r       : std_logic_vector(19 downto 0) := (others => '0');
  signal capture_pending : std_logic := '0';

  -- Keep stereo atomic in one 40-bit memory.  The registered synchronous read
  -- is deliberate: an asynchronous array read maps this buffer into hundreds
  -- of LUTRAM primitives, while this simple-dual-port shape maps cleanly into
  -- block RAM.  fifo_read_data holds the head frame throughout both AXI beats,
  -- so a simultaneous write into a slot freed by the second beat is harmless.
  type sample_mem_t is array (natural range <>) of
    std_logic_vector(39 downto 0);
  signal fifo_mem : sample_mem_t(0 to FIFO_DEPTH_G - 1);
  signal fifo_read_data : std_logic_vector(39 downto 0) := (others => '0');
  signal fifo_wr_ptr : natural range 0 to FIFO_DEPTH_G - 1 := 0;
  signal fifo_rd_ptr : natural range 0 to FIFO_DEPTH_G - 1 := 0;
  signal fifo_level : natural range 0 to FIFO_DEPTH_G := 0;
  signal fifo_highwater : natural range 0 to FIFO_DEPTH_G := 0;

  type   tx_state_t is (TX_IDLE, TX_FETCH, TX_FIRST, TX_SECOND);
  signal tx_state : tx_state_t := TX_IDLE;

  signal frames  : unsigned(15 downto 0) := (others => '0');
  signal stalls  : unsigned(15 downto 0) := (others => '0');
  signal fifo_overflows : unsigned(15 downto 0) := (others => '0');
  signal capture_misses : unsigned(15 downto 0) := (others => '0');
  signal stall_run : unsigned(15 downto 0) := (others => '0');
  signal max_stall_run : unsigned(15 downto 0) := (others => '0');

  signal tvalid_i : std_logic := '0';
  signal tdata_i  : std_logic_vector(31 downto 0) := (others => '0');
  signal tid_i    : std_logic := '0';

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of aud_reset_pipe : signal is "TRUE";
  attribute ASYNC_REG of ctrl_meta : signal is "TRUE";
  attribute ASYNC_REG of ctrl_aud : signal is "TRUE";
  attribute ASYNC_REG of div_meta : signal is "TRUE";
  attribute ASYNC_REG of div_aud : signal is "TRUE";
  attribute ASYNC_REG of req_sync : signal is "TRUE";
  attribute ASYNC_REG of ack_sync : signal is "TRUE";
  attribute ASYNC_REG of frames_meta : signal is "TRUE";
  attribute ASYNC_REG of frames_sync : signal is "TRUE";
  attribute ASYNC_REG of stalls_meta : signal is "TRUE";
  attribute ASYNC_REG of stalls_sync : signal is "TRUE";
  attribute ASYNC_REG of overflows_meta : signal is "TRUE";
  attribute ASYNC_REG of overflows_sync : signal is "TRUE";
  attribute ASYNC_REG of misses_meta : signal is "TRUE";
  attribute ASYNC_REG of misses_sync : signal is "TRUE";
  attribute ASYNC_REG of fifo_level_meta : signal is "TRUE";
  attribute ASYNC_REG of fifo_level_sync : signal is "TRUE";
  attribute ASYNC_REG of fifo_high_meta : signal is "TRUE";
  attribute ASYNC_REG of fifo_high_sync : signal is "TRUE";
  attribute ASYNC_REG of max_stall_meta : signal is "TRUE";
  attribute ASYNC_REG of max_stall_sync : signal is "TRUE";

  attribute ram_style : string;
  attribute ram_style of fifo_mem : signal is "block";

  -- Sign-extend the 20-bit sample to 32 bits and slide it to wherever the sink
  -- expects it to sit.
  function place(sample : std_logic_vector(19 downto 0);
                 sh     : integer;
                 mute   : std_logic) return std_logic_vector is
    variable v : signed(31 downto 0);
  begin
    if mute = '1' then
      return (31 downto 0 => '0');
    end if;
    v := resize(signed(sample), 32);
    return std_logic_vector(shift_left(v, sh));
  end function;

begin

  assert FIFO_DEPTH_G <= 65535
    report "dp_audio_axis FIFO_DEPTH_G exceeds diagnostic register width"
    severity failure;

  s_axi_awready <= awready_i;
  s_axi_wready  <= wready_i;
  s_axi_bvalid  <= bvalid_i;
  s_axi_bresp   <= "00";
  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  s_axi_rdata   <= rdata_i;
  s_axi_rresp   <= "00";

  awready_i <= '1' when aw_held = '0' and bvalid_i = '0' else '0';
  wready_i  <= '1' when w_held  = '0' and bvalid_i = '0' else '0';
  arready_i <= '1' when rvalid_i = '0' else '0';

  m_axis_tvalid <= tvalid_i;
  m_axis_tdata  <= tdata_i;
  m_axis_tid(0) <= tid_i;

  shift_amt <= to_integer(unsigned(ctrl_aud(7 downto 4)));

  -- dp_audio_ref_clk arrives unbuffered; put it on a global buffer before it
  -- clocks anything, and hand the buffered version back to the PS.
  bufg_aud : BUFG port map (I => aud_clk_in, O => aud_clk);
  aud_clk_out <= aud_clk;

  -- The AXI reset is synchronized to pl_clk0.  Re-synchronize its deassertion
  -- before using it in the unrelated DisplayPort audio clock domain while
  -- retaining immediate assertion during a fabric reset.
  process (aud_clk, s_axi_aresetn)
  begin
    if s_axi_aresetn = '0' then
      aud_reset_pipe <= (others => '0');
    elsif rising_edge(aud_clk) then
      aud_reset_pipe(0) <= '1';
      aud_reset_pipe(1) <= aud_reset_pipe(0);
    end if;
  end process;
  aud_resetn <= aud_reset_pipe(1);

  ------------------------------------------------------------------------------
  -- Config into the audio domain, counters back out.
  ------------------------------------------------------------------------------
  process (aud_clk)
  begin
    if rising_edge(aud_clk) then
      ctrl_meta <= ctrl_reg;  ctrl_aud <= ctrl_meta;
      div_meta  <= div_reg;   div_aud  <= div_meta;
    end if;
  end process;

  process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      frames_meta <= frames;  frames_sync <= frames_meta;
      stalls_meta <= stalls;  stalls_sync <= stalls_meta;
      overflows_meta <= fifo_overflows;
      overflows_sync <= overflows_meta;
      misses_meta <= capture_misses;
      misses_sync <= misses_meta;
      fifo_level_meta <= to_unsigned(fifo_level, fifo_level_meta'length);
      fifo_level_sync <= fifo_level_meta;
      fifo_high_meta <= to_unsigned(fifo_highwater, fifo_high_meta'length);
      fifo_high_sync <= fifo_high_meta;
      max_stall_meta <= max_stall_run;
      max_stall_sync <= max_stall_meta;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Core clock domain: capture a coherent stereo pair when asked.
  ------------------------------------------------------------------------------
  process (core_clk)
  begin
    if rising_edge(core_clk) then
      req_sync <= req_sync(1 downto 0) & req_tog;
      if req_sync(2) /= req_sync(1) then
        cap_l   <= audio_left;
        cap_r   <= audio_right;
        ack_tog <= not ack_tog;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Stream clock domain: rate strobe, handshake, and the AXI4-Stream master.
  ------------------------------------------------------------------------------
  process (aud_clk)
    variable rate_tick_v : boolean;
    variable ack_event_v : boolean;
    variable push_v : boolean;
    variable pop_v : boolean;
    variable next_level_v : natural range 0 to FIFO_DEPTH_G;
    variable next_stall_v : unsigned(15 downto 0);
  begin
    if rising_edge(aud_clk) then
      if aud_resetn = '0' then
        rate_cnt <= (others => '0');
        tx_state <= TX_IDLE;
        tvalid_i <= '0';
        req_tog  <= '0';
        capture_pending <= '0';
        fifo_wr_ptr <= 0;
        fifo_rd_ptr <= 0;
        fifo_level <= 0;
        fifo_highwater <= 0;
        frames <= (others => '0');
        stalls <= (others => '0');
        fifo_overflows <= (others => '0');
        capture_misses <= (others => '0');
        stall_run <= (others => '0');
        max_stall_run <= (others => '0');
      else
        rate_tick_v := false;
        ack_event_v := ack_sync(2) /= ack_sync(1);
        push_v := false;
        pop_v := false;

        ack_sync <= ack_sync(1 downto 0) & ack_tog;

        if en_bit = '0' then
          -- Disabling is also a clean stream boundary: discard queued samples
          -- and any capture that was in flight, but retain diagnostics so a
          -- fault cannot be hidden by an off/on recovery.
          rate_cnt <= (others => '0');
          capture_pending <= '0';
          fifo_wr_ptr <= 0;
          fifo_rd_ptr <= 0;
          fifo_level <= 0;
          tvalid_i <= '0';
          tx_state <= TX_IDLE;
          stall_run <= (others => '0');
        else
          if rate_cnt >= div_aud then
            rate_cnt <= (others => '0');
            rate_tick_v := true;
          else
            rate_cnt <= rate_cnt + 1;
          end if;

          -- Consume the FIFO independently of sample capture.  Backpressure
          -- holds each AXI beat stable; once ready returns, queued frames drain
          -- as quickly as the sink permits without losing their order.
          case tx_state is
            when TX_IDLE =>
              tvalid_i <= '0';
              if fifo_level > 0 then
                -- Synchronous BRAM read.  The data is available in
                -- fifo_read_data on the next audio clock.
                fifo_read_data <= fifo_mem(fifo_rd_ptr);
                tx_state <= TX_FETCH;
              end if;

            when TX_FETCH =>
                tdata_i <= place(fifo_read_data(39 downto 20),
                                  shift_amt, mute_bit);
                tid_i <= swap_bit;
                tvalid_i <= '1';
                tx_state <= TX_FIRST;

            when TX_FIRST =>
              if m_axis_tready = '1' then
                tdata_i <= place(fifo_read_data(19 downto 0),
                                  shift_amt, mute_bit);
                tid_i <= not swap_bit;
                tvalid_i <= '1';
                tx_state <= TX_SECOND;
              end if;

            when TX_SECOND =>
              if m_axis_tready = '1' then
                tvalid_i <= '0';
                frames <= frames + 1;
                tx_state <= TX_IDLE;
                pop_v := true;
              end if;
          end case;

          if tvalid_i = '1' and m_axis_tready = '0' then
            stalls <= stalls + 1;
            if stall_run /= x"FFFF" then
              next_stall_v := stall_run + 1;
              stall_run <= next_stall_v;
              if next_stall_v > max_stall_run then
                max_stall_run <= next_stall_v;
              end if;
            end if;
          else
            stall_run <= (others => '0');
          end if;

          -- The capture bus is stable before the synchronized acknowledgement
          -- arrives.  A simultaneous FIFO pop makes room for this push even
          -- when the queue was full at the start of the clock.
          if ack_event_v then
            capture_pending <= '0';
            if fifo_level < FIFO_DEPTH_G or pop_v then
              fifo_mem(fifo_wr_ptr) <= cap_l & cap_r;
              if fifo_wr_ptr = FIFO_DEPTH_G - 1 then
                fifo_wr_ptr <= 0;
              else
                fifo_wr_ptr <= fifo_wr_ptr + 1;
              end if;
              push_v := true;
            elsif fifo_overflows /= x"FFFF" then
              fifo_overflows <= fifo_overflows + 1;
            end if;
          end if;

          -- Ask for one coherent source sample on every exact 48 kHz tick.
          -- The normal round trip is only a few clocks; if it ever spans a
          -- complete sample period, record the missed capture explicitly.
          if rate_tick_v then
            if capture_pending = '0' or ack_event_v then
              req_tog <= not req_tog;
              capture_pending <= '1';
            elsif capture_misses /= x"FFFF" then
              capture_misses <= capture_misses + 1;
            end if;
          end if;

          if pop_v then
            if fifo_rd_ptr = FIFO_DEPTH_G - 1 then
              fifo_rd_ptr <= 0;
            else
              fifo_rd_ptr <= fifo_rd_ptr + 1;
            end if;
          end if;

          next_level_v := fifo_level;
          if push_v and not pop_v then
            next_level_v := next_level_v + 1;
          elsif pop_v and not push_v then
            next_level_v := next_level_v - 1;
          end if;
          fifo_level <= next_level_v;
          if next_level_v > fifo_highwater then
            fifo_highwater <= next_level_v;
          end if;
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- AXI4-Lite register file
  ------------------------------------------------------------------------------
  process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        ctrl_reg  <= (others => '0');
        ctrl_reg(7 downto 4) <= x"4";     -- default: 24-bit sample in [23:0]
        div_reg   <= to_unsigned(DIV_DEFAULT, 16);
        aw_held   <= '0';
        w_held    <= '0';
        bvalid_i  <= '0';
        rvalid_i  <= '0';
      else
        if awready_i = '1' and s_axi_awvalid = '1' then
          wr_addr <= s_axi_awaddr;
          aw_held <= '1';
        end if;

        if wready_i = '1' and s_axi_wvalid = '1' then
          wr_data <= s_axi_wdata;
          wr_strb <= s_axi_wstrb;
          w_held  <= '1';
        end if;

        if bvalid_i = '1' then
          if s_axi_bready = '1' then
            bvalid_i <= '0';
          end if;
        elsif aw_held = '1' and w_held = '1' then
          case wr_addr(4 downto 2) is
            when "000" =>
              if wr_strb(0) = '1' then
                ctrl_reg <= wr_data(7 downto 0);
              end if;
            when "001" =>
              if wr_strb(0) = '1' then
                div_reg(7 downto 0) <= unsigned(wr_data(7 downto 0));
              end if;
              if wr_strb(1) = '1' then
                div_reg(15 downto 8) <= unsigned(wr_data(15 downto 8));
              end if;
            when others => null;
          end case;
          aw_held   <= '0';
          w_held    <= '0';
          bvalid_i <= '1';
        end if;

        if rvalid_i = '1' then
          if s_axi_rready = '1' then
            rvalid_i <= '0';
          end if;
        elsif arready_i = '1' and s_axi_arvalid = '1' then
          case s_axi_araddr(4 downto 2) is
            when "000" => rdata_i <= x"000000" & ctrl_reg;
            when "001" => rdata_i <= x"0000" & std_logic_vector(div_reg);
            when "010" => rdata_i <= x"4D363541";                  -- "M65A"
            when "011" => rdata_i <= std_logic_vector(stalls_sync) &
                                      std_logic_vector(frames_sync);
            when "100" => rdata_i <= std_logic_vector(misses_sync) &
                                      std_logic_vector(overflows_sync);
            when "101" => rdata_i <= std_logic_vector(fifo_high_sync) &
                                      std_logic_vector(fifo_level_sync);
            when "110" => rdata_i <=
                std_logic_vector(to_unsigned(FIFO_DEPTH_G, 16)) &
                std_logic_vector(max_stall_sync);
            when "111" => rdata_i <= x"41554631";                 -- "AUF1"
            when others => rdata_i <= (others => '0');
          end case;
          rvalid_i <= '1';
        end if;
      end if;
    end if;
  end process;

end rtl;
