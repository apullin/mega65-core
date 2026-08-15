--------------------------------------------------------------------------------
-- In-context top level for the MEGA65 on the Kria KV260.
--
-- Joins two things:
--   * kv260_ps_wrapper -- the Zynq UltraScale+ PS block design, configured with
--     the DisplayPort controller's live-video input enabled (see kv260_ps_bd.tcl).
--     It supplies pl_clk0 (100 MHz) and consumes the video stream.
--   * container        -- the MEGA65 core proper (src/vhdl/kv260.vhdl).
--
-- The only PL package pins used are the eleven the carrier card actually brings
-- out (see kv260.xdc). Video does not touch a pin: it goes into the PS.
--
-- The CIA1 keyboard matrix has nowhere to go on this board -- all eleven pins
-- are spoken for by SD, UART, audio and status -- so porta/portb are terminated
-- locally. A real keyboard needs a PMOD adapter or a PS-side USB HID bridge.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity kv260_top is
  port (
    -- SD card (SPI)
    sd_reset : out std_logic;
    sd_clock : out std_logic;
    sd_mosi  : out std_logic;
    sd_miso  : in  std_logic;

    -- Serial monitor
    uart_txd : out std_logic;
    rsrx     : in  std_logic;

    -- Audio (PWM)
    pwm_l : out std_logic;
    pwm_r : out std_logic;

    -- Status / control.  fan_en is the PS TTC0 channel-2 waveform used by
    -- Ubuntu's stock thermal fan policy; the carrier routes it to package A12.
    led          : out std_logic;
    reset_button : in  std_logic;
    fan_en       : out std_logic
  );
end kv260_top;

architecture Behavioral of kv260_top is

  component kv260_ps_wrapper is
    port (
      dp_live_video_in_de     : in  std_logic;
      dp_live_video_in_hsync  : in  std_logic;
      dp_live_video_in_pixel1 : in  std_logic_vector(35 downto 0);
      dp_live_video_in_vsync  : in  std_logic;
      dp_video_in_clk         : in  std_logic;
      attic_aresetn  : out std_logic;
      M_AXI_ATTIC_awaddr : in  std_logic_vector(31 downto 0);
      M_AXI_ATTIC_awprot : in  std_logic_vector(2 downto 0);
      M_AXI_ATTIC_awvalid : in  std_logic;
      M_AXI_ATTIC_awready : out std_logic;
      M_AXI_ATTIC_wdata : in  std_logic_vector(31 downto 0);
      M_AXI_ATTIC_wstrb : in  std_logic_vector(3 downto 0);
      M_AXI_ATTIC_wvalid : in  std_logic;
      M_AXI_ATTIC_wready : out std_logic;
      M_AXI_ATTIC_bresp : out std_logic_vector(1 downto 0);
      M_AXI_ATTIC_bvalid : out std_logic;
      M_AXI_ATTIC_bready : in  std_logic;
      M_AXI_ATTIC_araddr : in  std_logic_vector(31 downto 0);
      M_AXI_ATTIC_arprot : in  std_logic_vector(2 downto 0);
      M_AXI_ATTIC_arvalid : in  std_logic;
      M_AXI_ATTIC_arready : out std_logic;
      M_AXI_ATTIC_rdata : out std_logic_vector(31 downto 0);
      M_AXI_ATTIC_rresp : out std_logic_vector(1 downto 0);
      M_AXI_ATTIC_rvalid : out std_logic;
      M_AXI_ATTIC_rready : in  std_logic;
      audio_clk               : in  std_logic;
      audio_left              : in  std_logic_vector(19 downto 0);
      audio_right             : in  std_logic_vector(19 downto 0);
      mon_uart_tx             : out std_logic;
      mon_uart_rx             : in  std_logic;
      axi_virt_f011           : out std_logic_vector(1 downto 0);
      axi_media_present_f011  : out std_logic_vector(1 downto 0);
      axi_d64_f011            : out std_logic_vector(1 downto 0);
      axi_write_protect_f011  : out std_logic_vector(1 downto 0);
      axi_disk_changed_f011   : out std_logic;
      vkbd_key1               : out std_logic_vector(7 downto 0);
      vkbd_key2               : out std_logic_vector(7 downto 0);
      vkbd_key3               : out std_logic_vector(7 downto 0);
      vkbd_restore            : out std_logic;
      vkbd_joya               : out std_logic_vector(4 downto 0);
      vkbd_joyb               : out std_logic_vector(4 downto 0);
      emio_ttc0_wave_o        : out std_logic_vector(2 downto 0);
      pl_clk0                 : out std_logic;
      pl_resetn0              : out std_logic
    );
  end component;

  -- Remote keyboard bytes from the PS-driven virtual_keyboard_axi slave.
  -- F011 virtualisation asserted from Linux, via the f011_ctrl_axi slave.
  signal axi_virt_f011 : std_logic_vector(1 downto 0);
  signal axi_media_present_f011 : std_logic_vector(1 downto 0);
  signal axi_d64_f011 : std_logic_vector(1 downto 0);
  signal axi_write_protect_f011 : std_logic_vector(1 downto 0);
  signal axi_disk_changed_f011 : std_logic;

  signal vkbd_key1 : std_logic_vector(7 downto 0);
  signal vkbd_key2 : std_logic_vector(7 downto 0);
  signal vkbd_key3 : std_logic_vector(7 downto 0);
  signal vkbd_restore : std_logic;
  signal vkbd_joya : std_logic_vector(4 downto 0);
  signal vkbd_joyb : std_logic_vector(4 downto 0);
  signal emio_ttc0_wave_o : std_logic_vector(2 downto 0);

  -- AXI-attached debug transport for the MEGA65 serial monitor.
  signal mon_uart_tx : std_logic;   -- from the AXI UART, into the monitor
  signal mon_uart_rx : std_logic;   -- from the monitor, into the AXI UART
  signal core_uart_txd : std_logic;

  signal pl_clk0    : std_logic;
  signal pl_resetn0 : std_logic;

  signal dp_video_in_clk         : std_logic;
  signal dp_live_video_in_pixel1 : std_logic_vector(35 downto 0);
  signal dp_live_video_in_hsync  : std_logic;
  signal dp_live_video_in_vsync  : std_logic;
  signal dp_live_video_in_de     : std_logic;

  -- Mixer output on its way to the DisplayPort live-audio input.  This board
  -- has no audio hardware, so sound rides out on the same cable as the picture.
  -- Attic RAM's AXI master, container -> PS DDR.
  signal attic_aresetn  : std_logic;
  signal attic_awaddr   : std_logic_vector(31 downto 0);
  signal attic_awprot   : std_logic_vector(2 downto 0);
  signal attic_awvalid  : std_logic;
  signal attic_awready  : std_logic;
  signal attic_wdata    : std_logic_vector(31 downto 0);
  signal attic_wstrb    : std_logic_vector(3 downto 0);
  signal attic_wvalid   : std_logic;
  signal attic_wready   : std_logic;
  signal attic_bresp    : std_logic_vector(1 downto 0);
  signal attic_bvalid   : std_logic;
  signal attic_bready   : std_logic;
  signal attic_araddr   : std_logic_vector(31 downto 0);
  signal attic_arprot   : std_logic_vector(2 downto 0);
  signal attic_arvalid  : std_logic;
  signal attic_arready  : std_logic;
  signal attic_rdata    : std_logic_vector(31 downto 0);
  signal attic_rresp    : std_logic_vector(1 downto 0);
  signal attic_rvalid   : std_logic;
  signal attic_rready   : std_logic;

  signal audio_clk   : std_logic;
  signal audio_left  : std_logic_vector(19 downto 0);
  signal audio_right : std_logic_vector(19 downto 0);

  -- CIA1 keyboard matrix: no pins available on this carrier.
  signal porta_pins : std_logic_vector(7 downto 0);
  signal portb_pins : std_logic_vector(7 downto 0);

begin

  ps0 : kv260_ps_wrapper
    port map (
      dp_video_in_clk         => dp_video_in_clk,
      dp_live_video_in_pixel1 => dp_live_video_in_pixel1,
      dp_live_video_in_hsync  => dp_live_video_in_hsync,
      dp_live_video_in_vsync  => dp_live_video_in_vsync,
      dp_live_video_in_de     => dp_live_video_in_de,
      attic_aresetn  => attic_aresetn,
      M_AXI_ATTIC_awaddr   => attic_awaddr,
      M_AXI_ATTIC_awprot   => attic_awprot,
      M_AXI_ATTIC_awvalid  => attic_awvalid,
      M_AXI_ATTIC_awready  => attic_awready,
      M_AXI_ATTIC_wdata    => attic_wdata,
      M_AXI_ATTIC_wstrb    => attic_wstrb,
      M_AXI_ATTIC_wvalid   => attic_wvalid,
      M_AXI_ATTIC_wready   => attic_wready,
      M_AXI_ATTIC_bresp    => attic_bresp,
      M_AXI_ATTIC_bvalid   => attic_bvalid,
      M_AXI_ATTIC_bready   => attic_bready,
      M_AXI_ATTIC_araddr   => attic_araddr,
      M_AXI_ATTIC_arprot   => attic_arprot,
      M_AXI_ATTIC_arvalid  => attic_arvalid,
      M_AXI_ATTIC_arready  => attic_arready,
      M_AXI_ATTIC_rdata    => attic_rdata,
      M_AXI_ATTIC_rresp    => attic_rresp,
      M_AXI_ATTIC_rvalid   => attic_rvalid,
      M_AXI_ATTIC_rready   => attic_rready,
      audio_clk               => audio_clk,
      audio_left              => audio_left,
      audio_right             => audio_right,
      mon_uart_tx             => mon_uart_tx,
      mon_uart_rx             => mon_uart_rx,
      axi_virt_f011           => axi_virt_f011,
      axi_media_present_f011  => axi_media_present_f011,
      axi_d64_f011            => axi_d64_f011,
      axi_write_protect_f011  => axi_write_protect_f011,
      axi_disk_changed_f011   => axi_disk_changed_f011,
      vkbd_key1               => vkbd_key1,
      vkbd_key2               => vkbd_key2,
      vkbd_key3               => vkbd_key3,
      vkbd_restore            => vkbd_restore,
      vkbd_joya               => vkbd_joya,
      vkbd_joyb               => vkbd_joyb,
      emio_ttc0_wave_o        => emio_ttc0_wave_o,
      pl_clk0                 => pl_clk0,
      pl_resetn0              => pl_resetn0
    );

  -- Linux's pwm-fan device uses TTC0 channel 2.  Pass that PS waveform to the
  -- carrier fan gate unchanged so the distro thermal curve remains in charge.
  fan_en <= emio_ttc0_wave_o(2);

  ----------------------------------------------------------------------------
  -- The MEGA65 serial monitor gets two transports at once: the physical pins
  -- and the AXI UART reachable from the host over JTAG.
  --
  -- Transmit fans out to both, which is free. For receive, a UART line idles
  -- high and is pulled low to signal, so AND-ing the two sources lets either
  -- one drive the monitor without a mux or arbitration. Talking on both at the
  -- same time would obviously collide; don't do that.
  ----------------------------------------------------------------------------
  uart_txd     <= core_uart_txd;
  mon_uart_rx  <= core_uart_txd;

  mega65 : entity work.container
    port map (
      clk_in       => pl_clk0,
      reset_button => reset_button,

      dp_video_in_clk         => dp_video_in_clk,
      dp_live_video_in_pixel1 => dp_live_video_in_pixel1,
      dp_live_video_in_hsync  => dp_live_video_in_hsync,
      dp_live_video_in_vsync  => dp_live_video_in_vsync,
      dp_live_video_in_de     => dp_live_video_in_de,

      attic_aresetn  => attic_aresetn,
      attic_awaddr   => attic_awaddr,
      attic_awprot   => attic_awprot,
      attic_awvalid  => attic_awvalid,
      attic_awready  => attic_awready,
      attic_wdata    => attic_wdata,
      attic_wstrb    => attic_wstrb,
      attic_wvalid   => attic_wvalid,
      attic_wready   => attic_wready,
      attic_bresp    => attic_bresp,
      attic_bvalid   => attic_bvalid,
      attic_bready   => attic_bready,
      attic_araddr   => attic_araddr,
      attic_arprot   => attic_arprot,
      attic_arvalid  => attic_arvalid,
      attic_arready  => attic_arready,
      attic_rdata    => attic_rdata,
      attic_rresp    => attic_rresp,
      attic_rvalid   => attic_rvalid,
      attic_rready   => attic_rready,
      audio_clk   => audio_clk,
      audio_left  => audio_left,
      audio_right => audio_right,

      -- This carrier has no physical RESTORE input.  Package pin A12 is the
      -- fan gate, so RESTORE comes exclusively from the active-low AXI
      -- keyboard control (Page Up in the host daemon).
      restore_key => vkbd_restore,
      axi_virt_f011 => axi_virt_f011,
      axi_media_present_f011 => axi_media_present_f011,
      axi_d64_f011 => axi_d64_f011,
      axi_write_protect_f011 => axi_write_protect_f011,
      axi_disk_changed_f011 => axi_disk_changed_f011,
      vkbd_key1   => unsigned(vkbd_key1),
      vkbd_key2   => unsigned(vkbd_key2),
      vkbd_key3   => unsigned(vkbd_key3),
      vjoy_a      => vkbd_joya,
      vjoy_b      => vkbd_joyb,
      porta_pins  => porta_pins,
      portb_pins  => portb_pins,

      sd_reset => sd_reset,
      sd_clock => sd_clock,
      sd_mosi  => sd_mosi,
      sd_miso  => sd_miso,

      uart_txd => core_uart_txd,
      rsrx     => rsrx and mon_uart_tx,

      pwm_l => pwm_l,
      pwm_r => pwm_r,

      led => led
    );

end Behavioral;
