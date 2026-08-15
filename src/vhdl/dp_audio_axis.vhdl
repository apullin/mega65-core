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
  port (
    -- AXI4-Lite control, on the interconnect's clock
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;

    -- dp_audio_ref_clk straight from the PS, and the same clock after a global
    -- buffer.  aud_clk_out goes back to the PS as dp_s_axis_audio_clk so the
    -- stream master and slave are genuinely the same clock.
    aud_clk_in  : in  std_logic;
    aud_clk_out : out std_logic;

    s_axi_awaddr  : in  std_logic_vector(3 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;

    s_axi_araddr  : in  std_logic_vector(3 downto 0);
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
  signal wr_addr   : std_logic_vector(3 downto 0) := (others => '0');
  signal wr_data   : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_strb   : std_logic_vector(3 downto 0) := (others => '0');
  signal aw_held   : std_logic := '0';
  signal w_held    : std_logic := '0';

  -- Sample-rate strobe
  signal rate_cnt : unsigned(15 downto 0) := (others => '0');
  signal frame_go : std_logic := '0';

  ------------------------------------------------------------------------------
  -- Clock crossing, destination-driven.
  --
  -- The stream side asks for a sample by toggling req; the core side sees the
  -- toggle, latches both channels at one instant (so left and right are always
  -- from the same moment) and toggles ack.  Between the ack and the next req
  -- the captured pair is guaranteed not to move, so the stream side can read it
  -- as ordinary stable data.  No FIFO needed: we consume exactly one sample per
  -- frame and never need to buffer.
  ------------------------------------------------------------------------------
  signal req_tog     : std_logic := '0';
  signal req_sync    : std_logic_vector(2 downto 0) := (others => '0');
  signal ack_tog     : std_logic := '0';
  signal ack_sync    : std_logic_vector(2 downto 0) := (others => '0');
  signal cap_l       : std_logic_vector(19 downto 0) := (others => '0');
  signal cap_r       : std_logic_vector(19 downto 0) := (others => '0');
  signal hold_l      : std_logic_vector(19 downto 0) := (others => '0');
  signal hold_r      : std_logic_vector(19 downto 0) := (others => '0');

  type   tx_state_t is (TX_IDLE, TX_FIRST, TX_SECOND);
  signal tx_state : tx_state_t := TX_IDLE;

  signal frames  : unsigned(15 downto 0) := (others => '0');
  signal stalls  : unsigned(15 downto 0) := (others => '0');

  signal tvalid_i : std_logic := '0';
  signal tdata_i  : std_logic_vector(31 downto 0) := (others => '0');
  signal tid_i    : std_logic := '0';

  -- Tell Vivado which generated module-reference clock owns the AXIS bus.  A
  -- name-inferred interface alone does not associate aud_clk_out with M_AXIS,
  -- which produced BD 41-967 and left its frequency at a bogus 100 MHz.
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
  begin
    if rising_edge(aud_clk) then
      if aud_resetn = '0' then
        rate_cnt <= (others => '0');
        frame_go <= '0';
        tx_state <= TX_IDLE;
        tvalid_i <= '0';
        req_tog  <= '0';
        frames   <= (others => '0');
        stalls   <= (others => '0');
      else
        -- sample rate strobe
        frame_go <= '0';
        if rate_cnt >= div_aud then
          rate_cnt <= (others => '0');
          frame_go <= '1';
        else
          rate_cnt <= rate_cnt + 1;
        end if;

        ack_sync <= ack_sync(1 downto 0) & ack_tog;
        if ack_sync(2) /= ack_sync(1) then
          -- capture complete; the pair is stable until we ask again
          hold_l <= cap_l;
          hold_r <= cap_r;
        end if;

        case tx_state is
          when TX_IDLE =>
            tvalid_i <= '0';
            if frame_go = '1' and en_bit = '1' then
              req_tog  <= not req_tog;      -- ask the core for the next pair
              tdata_i  <= place(hold_l, shift_amt, mute_bit);
              tid_i    <= swap_bit;         -- swap_bit=0 => left is tid 0
              tvalid_i <= '1';
              tx_state <= TX_FIRST;
            end if;

          when TX_FIRST =>
            if m_axis_tready = '1' then
              tdata_i  <= place(hold_r, shift_amt, mute_bit);
              tid_i    <= not swap_bit;
              tvalid_i <= '1';
              tx_state <= TX_SECOND;
            else
              stalls <= stalls + 1;
            end if;

          when TX_SECOND =>
            if m_axis_tready = '1' then
              tvalid_i <= '0';
              frames   <= frames + 1;
              tx_state <= TX_IDLE;
            else
              stalls <= stalls + 1;
            end if;
        end case;

        if en_bit = '0' then
          tvalid_i <= '0';
          tx_state <= TX_IDLE;
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
          case wr_addr(3 downto 2) is
            when "00" =>
              if wr_strb(0) = '1' then
                ctrl_reg <= wr_data(7 downto 0);
              end if;
            when "01" =>
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
          case s_axi_araddr(3 downto 2) is
            when "00"   => rdata_i <= x"000000" & ctrl_reg;
            when "01"   => rdata_i <= x"0000" & std_logic_vector(div_reg);
            when "10"   => rdata_i <= x"4D363541";                  -- "M65A"
            when others => rdata_i <= std_logic_vector(stalls_sync) &
                                      std_logic_vector(frames_sync);
          end case;
          rvalid_i <= '1';
        end if;
      end if;
    end if;
  end process;

end rtl;
