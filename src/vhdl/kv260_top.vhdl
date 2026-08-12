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

    -- Status / control
    led          : out std_logic;
    reset_button : in  std_logic;
    restore_key  : in  std_logic
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
      mon_uart_tx             : out std_logic;
      mon_uart_rx             : in  std_logic;
      vkbd_key1               : out std_logic_vector(7 downto 0);
      vkbd_key2               : out std_logic_vector(7 downto 0);
      vkbd_key3               : out std_logic_vector(7 downto 0);
      pl_clk0                 : out std_logic;
      pl_resetn0              : out std_logic
    );
  end component;

  -- Remote keyboard bytes from the PS-driven virtual_keyboard_axi slave.
  signal vkbd_key1 : std_logic_vector(7 downto 0);
  signal vkbd_key2 : std_logic_vector(7 downto 0);
  signal vkbd_key3 : std_logic_vector(7 downto 0);

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
      mon_uart_tx             => mon_uart_tx,
      mon_uart_rx             => mon_uart_rx,
      vkbd_key1               => vkbd_key1,
      vkbd_key2               => vkbd_key2,
      vkbd_key3               => vkbd_key3,
      pl_clk0                 => pl_clk0,
      pl_resetn0              => pl_resetn0
    );

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

      restore_key => restore_key,
      vkbd_key1   => unsigned(vkbd_key1),
      vkbd_key2   => unsigned(vkbd_key2),
      vkbd_key3   => unsigned(vkbd_key3),
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
