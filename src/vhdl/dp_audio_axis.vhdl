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
-- So the stream now runs on dp_audio_ref_clk (24.242 MHz here), which is what
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
  -- reports 24.242 MHz for this output; the driver reprograms it, so trust the
  -- hardware, not the preset.)  Dividing by 512 therefore lands exactly on
  -- 48 kHz with no error at all.
  constant DIV_DEFAULT : natural := 511;

  signal aud_clk : std_logic;

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

  m_axis_tvalid <= tvalid_i;
  m_axis_tdata  <= tdata_i;
  m_axis_tid(0) <= tid_i;

  shift_amt <= to_integer(unsigned(ctrl_aud(7 downto 4)));

  -- dp_audio_ref_clk arrives unbuffered; put it on a global buffer before it
  -- clocks anything, and hand the buffered version back to the PS.
  bufg_aud : BUFG port map (I => aud_clk_in, O => aud_clk);
  aud_clk_out <= aud_clk;

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
      if s_axi_aresetn = '0' then
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
    variable do_write : boolean;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        ctrl_reg  <= (others => '0');
        ctrl_reg(7 downto 4) <= x"4";     -- default: 24-bit sample in [23:0]
        div_reg   <= to_unsigned(DIV_DEFAULT, 16);
        awready_i <= '0';
        wready_i  <= '0';
        bvalid_i  <= '0';
        arready_i <= '0';
        rvalid_i  <= '0';
      else
        if awready_i = '0' and s_axi_awvalid = '1' then
          awready_i <= '1';
          wr_addr   <= s_axi_awaddr;
        else
          awready_i <= '0';
        end if;

        do_write := false;
        if wready_i = '0' and s_axi_wvalid = '1' then
          wready_i <= '1';
          do_write := true;
        else
          wready_i <= '0';
        end if;

        if do_write then
          case wr_addr(3 downto 2) is
            when "00"   => ctrl_reg <= s_axi_wdata(7 downto 0);
            when "01"   => div_reg  <= unsigned(s_axi_wdata(15 downto 0));
            when others => null;
          end case;
          bvalid_i <= '1';
        elsif bvalid_i = '1' and s_axi_bready = '1' then
          bvalid_i <= '0';
        end if;

        if arready_i = '0' and s_axi_arvalid = '1' then
          arready_i <= '1';
          case s_axi_araddr(3 downto 2) is
            when "00"   => rdata_i <= x"000000" & ctrl_reg;
            when "01"   => rdata_i <= x"0000" & std_logic_vector(div_reg);
            when "10"   => rdata_i <= x"4D363541";                  -- "M65A"
            when others => rdata_i <= std_logic_vector(stalls_sync) &
                                      std_logic_vector(frames_sync);
          end case;
          rvalid_i <= '1';
        else
          arready_i <= '0';
          if rvalid_i = '1' and s_axi_rready = '1' then
            rvalid_i <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

end rtl;
