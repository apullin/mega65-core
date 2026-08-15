--------------------------------------------------------------------------------
-- MEGA65 target: AMD/Xilinx Kria KV260 Vision AI Starter Kit (XCK26, ZU5EV).
--
-- Derived from wukong.vhdl, which is the smallest existing "generic FPGA board"
-- target and therefore the cleanest base for a new board.
--
-- Board realities that shape this file (from UG1089 and the K26 SOM data sheet):
--
--  * There are NO video pins on the PL.  Both the HDMI (J5) and DisplayPort (J6)
--    connectors on the carrier card are fed by an STDP4320 video splitter whose
--    input is the PS DisplayPort controller on PS-GTR lanes.  We therefore do
--    NOT generate TMDS here.  Instead the core's native parallel RGB + syncs are
--    exported and handed to the PS DisplayPort controller's "live video" input
--    (a 36-bit native video interface, DPDMA bypassed).  That interface wants
--    exactly what the VIC-IV already produces, so the pixel path is unchanged.
--
--    Consequence: vga_to_hdmi and serialiser_10to1_selectio are both dropped,
--    which also removes the only OSERDESE2 instances in the design.
--
--  * There is no PL-attached DRAM on the K26 SOM (the 4 GB DDR4 belongs to the
--    PS).  HyperRAM is therefore not installed; the core supports this directly
--    via hyper_installed => false, exactly as the wukong target does.
--
--  * The PL cannot reach the configuration flash: the PL is configured by the
--    PS.  STARTUPE2/ICAPE2-based core-switching is not applicable, so the QSPI
--    interface is left unconnected rather than ported to STARTUPE3/ICAPE3.
--
--  * XADC does not exist on UltraScale+ (it is SYSMONE4).  Die temperature is
--    not on the critical path for bring-up, so it is stubbed to a fixed value
--    and left as a follow-up.
--
-- Status: this is the Milestone-1 top level.  It is intended to be synthesised
-- out-of-context to establish that the core builds for UltraScale+ and to
-- measure utilisation on the XCK26.  Wiring the video bus to the PS DisplayPort
-- controller and adding real pin constraints is Milestone 2.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library UNISIM;
use UNISIM.vcomponents.all;

library STD;
use STD.textio.all;

use work.cputypes.all;
use work.types_pkg.all;

entity container is
  port (
    -- 100 MHz reference.  On the assembled design this is PS pl_clk0.
    clk_in       : in std_logic;
    reset_button : in std_logic;

    ------------------------------------------------------------------------
    -- Video, in the exact shape the PS DisplayPort controller's live-video
    -- input expects.  Port names match the zynq_ultra_ps_e pins 1:1 so the
    -- block design connects without glue logic:
    --
    --   dp_video_in_clk           (PL supplies the pixel clock to the PS)
    --   dp_live_video_in_pixel1   36-bit, 3 x 12-bit components
    --   dp_live_video_in_hsync / _vsync / _de
    ------------------------------------------------------------------------
    dp_video_in_clk         : out std_logic;
    dp_live_video_in_pixel1 : out std_logic_vector(35 downto 0);
    dp_live_video_in_hsync  : out std_logic;
    dp_live_video_in_vsync  : out std_logic;
    dp_live_video_in_de     : out std_logic;

    ------------------------------------------------------------------------
    -- Audio, for the DisplayPort live-audio input.
    --
    -- This carrier has no audio hardware: ampPWM_l/r go to PMOD pins with
    -- nothing on them.  So sound leaves the same way the picture does,
    -- embedded in the DisplayPort stream.  These are the mixer's raw 20-bit
    -- samples in the cpuclock domain; dp_audio_axis does the clock crossing
    -- and the AXI4-Stream framing.
    ------------------------------------------------------------------------
    -- Attic RAM's AXI master, out to a PS high-performance slave port.
    attic_aresetn : in  std_logic := '0';
    attic_awaddr  : out std_logic_vector(31 downto 0);
    attic_awprot  : out std_logic_vector(2 downto 0);
    attic_awvalid : out std_logic;
    attic_awready : in  std_logic := '0';
    attic_wdata   : out std_logic_vector(31 downto 0);
    attic_wstrb   : out std_logic_vector(3 downto 0);
    attic_wvalid  : out std_logic;
    attic_wready  : in  std_logic := '0';
    attic_bresp   : in  std_logic_vector(1 downto 0) := "00";
    attic_bvalid  : in  std_logic := '0';
    attic_bready  : out std_logic;
    attic_araddr  : out std_logic_vector(31 downto 0);
    attic_arprot  : out std_logic_vector(2 downto 0);
    attic_arvalid : out std_logic;
    attic_arready : in  std_logic := '0';
    attic_rdata   : in  std_logic_vector(31 downto 0) := (others => '0');
    attic_rresp   : in  std_logic_vector(1 downto 0) := "00";
    attic_rvalid  : in  std_logic := '0';
    attic_rready  : out std_logic;

    audio_clk   : out std_logic;
    audio_left  : out std_logic_vector(19 downto 0);
    audio_right : out std_logic_vector(19 downto 0);

    ------------------------------------------------------------------------
    -- Keyboard (CIA1 matrix).  Destined for a PMOD-attached keyboard or a
    -- PS-side USB HID bridge; exported for now.
    ------------------------------------------------------------------------
    restore_key : in    std_logic;
    porta_pins  : inout std_logic_vector(7 downto 0);
    portb_pins  : inout std_logic_vector(7 downto 0);

    -- Remote keyboard, injected from the PS over AXI (this board has no keyboard
    -- pins). Driven by the virtual_keyboard_axi slave in the block design, via
    -- kv260_top. MEGA65 matrix positions 0..71, 0xFF = no key.
    -- F011 virtualisation, asserted from Linux over AXI.  See
    -- f011_ctrl_axi.vhdl for why this exists rather than going through $D659.
    axi_virt_f011 : in std_logic_vector(1 downto 0) := "00";
    axi_media_present_f011 : in std_logic_vector(1 downto 0) := "00";
    axi_d64_f011 : in std_logic_vector(1 downto 0) := "00";
    axi_write_protect_f011 : in std_logic_vector(1 downto 0) := "00";
    axi_disk_changed_f011 : in std_logic := '0';

    vkbd_key1 : in unsigned(7 downto 0) := x"FF";
    vkbd_key2 : in unsigned(7 downto 0) := x"FF";
    vkbd_key3 : in unsigned(7 downto 0) := x"FF";

    ------------------------------------------------------------------------
    -- SD card, SPI mode (PMOD).
    ------------------------------------------------------------------------
    sd_reset : out std_logic;
    sd_clock : out std_logic;
    sd_mosi  : out std_logic;
    sd_miso  : in  std_logic;

    -- Serial monitor.
    uart_txd : out std_logic;
    rsrx     : in  std_logic;

    -- Audio (PWM, PMOD).
    pwm_l : out std_logic;
    pwm_r : out std_logic;

    -- Status LED.
    led : out std_logic
  );
end container;

architecture Behavioral of container is

  signal irq                  : std_logic := '1';
  signal nmi                  : std_logic := '1';
  signal reset_out            : std_logic := '1';
  signal btncpureset          : std_logic := '1';
  signal cpuclock             : std_logic;
  signal pixelclock           : std_logic;
  signal clock27              : std_logic;
  signal clock81n             : std_logic;
  signal clock135p            : std_logic;
  signal clock135n            : std_logic;
  signal clock162             : std_logic;
  signal clocks_locked        : std_logic;
  signal sector_buffer_mapped : std_logic;

  -- Die temperature is reported as zero, not measured. XADC does not exist on
  -- UltraScale+ and the SYSMONE4 equivalent is not wired up yet, so anything
  -- reading $D62E..F on this target gets a constant. Follow-up, not a blocker.
  signal fpga_temperature : std_logic_vector(11 downto 0) := (others => '0');

  -- SYSCTL configuration register.
  signal portp       : unsigned(7 downto 0);
  signal portp_drive : unsigned(7 downto 0);

  -- Keyboard port B charge control (as per the wukong target).
  signal portb_charge_pins : std_logic;
  signal portb_pins_in     : std_logic_vector(7 downto 0);

  -- Audio.  The internal names carry the mixer output; the like-named output
  -- ports are driven from them, since an "out" port cannot be read back.
  signal audio_left_i  : std_logic_vector(19 downto 0);
  signal audio_right_i : std_logic_vector(19 downto 0);

  -- OPL2/3 FM synthesiser output, from slow_devices into the audio mixer.
  -- The wukong target this file descends from leaves these unconnected, which
  -- leaves the OPL3's outputs dangling and lets Vivado trim the entire FM core
  -- out of the design. The real MEGA65 boards (r3/r4/r6) wire them up; so do we.
  signal fm_left  : signed(15 downto 0);
  signal fm_right : signed(15 downto 0);

  -- Video.
  signal v_hdmi_hsync    : std_logic;
  signal v_vsync         : std_logic;
  signal v_red           : unsigned(7 downto 0);
  signal v_green         : unsigned(7 downto 0);
  signal v_blue          : unsigned(7 downto 0);
  signal hdmi_dataenable : std_logic;

  -- QSPI flash: not reachable from the PL on this board.  The core still
  -- drives these, so they are terminated locally.
  signal qspi_clock  : std_logic;
  signal qspi_csn    : std_logic;
  signal qspi_db_oe  : std_logic;
  signal qspi_db_out : unsigned(3 downto 0);
  signal qspi_db_in  : unsigned(3 downto 0) := (others => '1');

  -- Slow device bus.
  signal slow_access_request_toggle : std_logic;
  signal slow_access_ready_toggle   : std_logic;
  signal slow_access_write          : std_logic;
  signal slow_access_address        : unsigned(27 downto 0);
  signal slow_access_wdata          : unsigned(7 downto 0);
  signal slow_access_rdata          : unsigned(7 downto 0);

  -- Expansion ("attic") RAM, backed by UltraRAM rather than a HyperRAM chip.
  signal expansionram_read              : std_logic;
  signal expansionram_write             : std_logic;
  signal expansionram_address           : unsigned(26 downto 0);
  signal expansionram_wdata             : unsigned(7 downto 0);
  signal expansionram_rdata             : unsigned(7 downto 0);
  signal expansionram_data_ready_toggle : std_logic;
  signal expansionram_busy              : std_logic;

  -- Cartridge port stubs (no expansion port on this board).
  signal cart_ba   : std_logic             := 'Z';
  signal cart_rw   : std_logic             := 'Z';
  signal cart_roml : std_logic             := 'Z';
  signal cart_romh : std_logic             := 'Z';
  signal cart_io1  : std_logic             := 'Z';
  signal cart_io2  : std_logic             := 'Z';
  signal cart_a    : unsigned(15 downto 0) := (others => 'Z');

begin

  -- Clocks.  UltraScale+ (MMCME4_ADV) equivalent of clocking50mhz, fed from
  -- 100 MHz rather than 50 MHz.
  clocks : entity work.clocking_kv260
    port map (
      clk_in    => clk_in,
      clock27   => clock27,     --  27   MHz
      clock41   => cpuclock,    --  40.5 MHz
      clock81p  => pixelclock,  --  81   MHz
      clock81n  => clock81n,
      clock135p => clock135p,
      clock135n => clock135n,
      clock162  => clock162,
      locked    => clocks_locked
    );

  -- Slow device manager.
  slow_devices0 : entity work.slow_devices
    generic map (
      target => kv260
    )
    port map (
      cpuclock             => cpuclock,
      pixelclock           => pixelclock,
      reset                => reset_out,
      sector_buffer_mapped => sector_buffer_mapped,

      slow_access_request_toggle => slow_access_request_toggle,
      slow_access_ready_toggle   => slow_access_ready_toggle,
      slow_access_write          => slow_access_write,
      slow_access_address        => slow_access_address,
      slow_access_wdata          => slow_access_wdata,
      slow_access_rdata          => slow_access_rdata,

      -- OPL2/3 FM synthesiser audio out to the mixer.
      fm_left  => fm_left,
      fm_right => fm_right,

      -- Expansion RAM. The K26 SOM has no PL-attached DRAM, so instead of a
      -- HyperRAM chip this is 2 MB of on-die UltraRAM (see expansionram_uram).
      expansionram_read              => expansionram_read,
      expansionram_write             => expansionram_write,
      expansionram_address           => expansionram_address,
      expansionram_wdata             => expansionram_wdata,
      expansionram_rdata             => expansionram_rdata,
      expansionram_data_ready_toggle => expansionram_data_ready_toggle,
      expansionram_busy              => expansionram_busy,

      -- No cartridge port.
      cart_nmi   => 'Z',
      cart_irq   => 'Z',
      cart_dma   => 'Z',
      cart_exrom => 'Z',
      cart_ba    => cart_ba,
      cart_rw    => cart_rw,
      cart_roml  => cart_roml,
      cart_romh  => cart_romh,
      cart_io1   => cart_io1,
      cart_game  => 'Z',
      cart_io2   => cart_io2,
      cart_d_in  => (others => 'Z'),
      cart_a     => cart_a
    );

  ----------------------------------------------------------------------------
  -- Expansion ("attic") RAM in UltraRAM.
  --
  -- Real MEGA65 boards put 8 MB of HyperRAM here. The K26 SOM has no PL-attached
  -- DRAM at all, but it does have 64 UltraRAM blocks that nothing else in the
  -- design uses, which is 2 MB of on-die memory with no external chip.
  --
  -- Clocked from pixelclock because that is the clock slow_devices' expansion
  -- RAM state machine runs on.
  --
  -- Note: this is 2 MB, not the 8 MB of real hardware, and addresses above that
  -- alias rather than fault. hyper_installed stays false below, so the VIC-IV
  -- does not try to fetch glyphs from here -- that needs the controller's
  -- separate viciv_* port set, which is a follow-up.
  ----------------------------------------------------------------------------
  -- Attic RAM lives in PS DDR rather than UltraRAM.  The XCK26 has 64 URAM
  -- blocks = 2 MB, and the MEGA65 expects 8 MB, so the URAM version aliased
  -- four ways -- software assuming 8 MB corrupted itself quietly.  DDR gives
  -- the real size, and costs nothing in the fabric.  See expansionram_axi.vhdl
  -- for why this does not make the machine depend on Linux.
  atticram0 : entity work.expansionram_axi
    generic map (
      BASE_ADDR => x"78000000",    -- must be reserved from Linux
      ADDR_BITS => 23              -- 8 MB
    )
    port map (
      clock             => pixelclock,
      address           => expansionram_address,
      wdata             => expansionram_wdata,
      read_request      => expansionram_read,
      write_request     => expansionram_write,
      rdata             => expansionram_rdata,
      data_ready_toggle => expansionram_data_ready_toggle,
      busy              => expansionram_busy,

      m_axi_aclk    => clk_in,
      m_axi_aresetn => attic_aresetn,
      m_axi_awaddr  => attic_awaddr,
      m_axi_awprot  => attic_awprot,
      m_axi_awvalid => attic_awvalid,
      m_axi_awready => attic_awready,
      m_axi_wdata   => attic_wdata,
      m_axi_wstrb   => attic_wstrb,
      m_axi_wvalid  => attic_wvalid,
      m_axi_wready  => attic_wready,
      m_axi_bresp   => attic_bresp,
      m_axi_bvalid  => attic_bvalid,
      m_axi_bready  => attic_bready,
      m_axi_araddr  => attic_araddr,
      m_axi_arprot  => attic_arprot,
      m_axi_arvalid => attic_arvalid,
      m_axi_arready => attic_arready,
      m_axi_rdata   => attic_rdata,
      m_axi_rresp   => attic_rresp,
      m_axi_rvalid  => attic_rvalid,
      m_axi_rready  => attic_rready
    );

  -- MEGA65 main component.
  machine0 : entity work.machine
    generic map (
      cpu_frequency   => 40500000,
      target          => kv260,
      hyper_installed => false
    )
    port map (
      axi_virt_f011 => axi_virt_f011,
      axi_media_present_f011 => axi_media_present_f011,
      axi_d64_f011 => axi_d64_f011,
      axi_write_protect_f011 => axi_write_protect_f011,
      axi_disk_changed_f011 => axi_disk_changed_f011,
      pixelclock           => pixelclock,
      cpuclock             => cpuclock,
      uartclock            => cpuclock,
      clock162             => clock162,
      clock200             => '0',
      clock27              => clock27,
      clock50mhz           => '0',
      no_hyppo             => '0',
      kbd_datestamp        => (others => '0'),
      kbd_commit           => (others => '0'),
      btncpureset          => btncpureset,
      reset_out            => reset_out,
      irq                  => irq,
      nmi                  => nmi,
      restore_key          => restore_key,
      cpu_exrom            => '1',
      cpu_game             => '1',
      sector_buffer_mapped => sector_buffer_mapped,
      fpga_temperature     => fpga_temperature,

      -- QSPI flash (terminated locally; PL has no access to config flash here).
      qspi_clock => qspi_clock,
      qspicsn    => qspi_csn,
      qspidb     => qspi_db_out,
      qspidb_in  => qspi_db_in,
      qspidb_oe  => qspi_db_oe,

      -- Audio.
      audio_left  => audio_left_i,
      audio_right => audio_right_i,
      ampPWM_l    => pwm_l,
      ampPWM_r    => pwm_r,
      fm_left     => fm_left,
      fm_right    => fm_right,

      -- Video.
      vsync           => v_vsync,
      hdmi_hsync      => v_hdmi_hsync,
      vgared          => v_red,
      vgagreen        => v_green,
      vgablue         => v_blue,
      hdmi_dataenable => hdmi_dataenable,

      -- Slow device bus.
      slow_access_request_toggle => slow_access_request_toggle,
      slow_access_ready_toggle   => slow_access_ready_toggle,
      slow_access_address        => slow_access_address,
      slow_access_write          => slow_access_write,
      slow_access_wdata          => slow_access_wdata,
      slow_access_rdata          => slow_access_rdata,

      -- CIA1 ports (physical keyboard and joysticks).
      porta_pins        => porta_pins,
      portb_pins        => portb_pins_in,
      portb_charge_pins => portb_charge_pins,
      caps_lock_key     => '1',
      keyleft           => '0',
      keyup             => '0',

      -- Remote keyboard injected from the PS over AXI (this board has no
      -- keyboard pins). See virtual_keyboard_axi / the vkbd BD slave.
      remote_key1       => vkbd_key1,
      remote_key2       => vkbd_key2,
      remote_key3       => vkbd_key3,
      fa_fire           => '1',
      fa_up             => '1',
      fa_left           => '1',
      fa_down           => '1',
      fa_right          => '1',
      fb_fire           => '1',
      fb_up             => '1',
      fb_left           => '1',
      fb_down           => '1',
      fb_right          => '1',
      fa_potx           => '0',
      fa_poty           => '0',
      fb_potx           => '0',
      fb_poty           => '0',

      -- Internal SD card (bus #1).
      cs_bo  => sd_reset,
      sclk_o => sd_clock,
      mosi_o => sd_mosi,
      miso_i => sd_miso,

      -- Serial monitor.
      UART_TXD => uart_txd,
      RsRx     => rsrx,

      -- SYSCTL configuration register.
      portp_out => portp,

      -- Switches and buttons.
      sw    => (others => '0'),
      dipsw => (others => '0'),
      btn   => (others => '1'),

      --------------------------------------------------------------------------
      -- Unsupported components and peripherals.
      --------------------------------------------------------------------------

      -- CBM floppy serial port (not supported).
      iec_data_external => '1',
      iec_clk_external  => '1',
      iec_srq_external  => '1',
      iec_bus_active    => '0',

      -- External SD card (bus #0, priority) (not supported).
      miso2_i => '1',

      -- Floppy drive interface (not supported).
      f_index        => '1',
      f_track0       => '1',
      f_writeprotect => '1',
      f_rdata        => '1',
      f_diskchanged  => '1',

      -- Ethernet controller (not supported; the PHY belongs to the PS).
      eth_rxd       => "00",
      eth_rxer      => '0',
      eth_rxdv      => '0',
      eth_interrupt => '0',

      -- Accelerometer (not supported).
      aclMISO => '1',
      aclInt1 => '1',
      aclInt2 => '1',

      -- Temperature sensor / I2C bus #0 (not supported).
      tmpint => '1',
      tmpct  => '1',

      -- Microphones (not supported).
      micData0 => '1',
      micData1 => '1',

      -- Buffered UART (not supported).
      buffereduart_ringindicate => (others => '0'),

      -- PS/2 keyboard (not supported).
      ps2data  => '1',
      ps2clock => '1',

      -- Widget board / MEGA65R2 keyboard (not supported).
      widget_matrix_col => (others => '1'),
      widget_restore    => '1',
      widget_capslock   => '1',
      widget_joya       => (others => '1'),
      widget_joyb       => (others => '1')
    );

  ----------------------------------------------------------------------------
  -- Video export to the PS DisplayPort controller's live-video input.
  --
  -- The VIC-IV already produces exactly this: 8:8:8 RGB with active-high
  -- syncs and a data-enable, on the 27 MHz pixel clock.  No TMDS encoding and
  -- no serialisation happens on this board.
  ----------------------------------------------------------------------------
  audio_clk   <= cpuclock;
  audio_left  <= audio_left_i;
  audio_right <= audio_right_i;

  dp_video_in_clk        <= clock27;
  dp_live_video_in_hsync <= v_hdmi_hsync;
  dp_live_video_in_vsync <= v_vsync;
  dp_live_video_in_de    <= hdmi_dataenable;

  -- The live-video bus carries three 12-bit components.  The VIC-IV produces
  -- 8 bits per component, so each is left-aligned into its 12-bit field with
  -- the low 4 bits zeroed.
  --
  -- NOTE: component ORDER on this bus is not yet confirmed against UG1085.
  -- The mapping below assumes {R, G, B} from MSB to LSB, which is the usual
  -- Xilinx convention for a 36-bit video bus.  If red and blue come out
  -- swapped on hardware, this single assignment is the only thing to change --
  -- a colour-bar test settles it in seconds.  Do not trust it until it has
  -- been seen on a monitor.
  dp_live_video_in_pixel1(35 downto 24) <= std_logic_vector(v_red)   & "0000";
  dp_live_video_in_pixel1(23 downto 12) <= std_logic_vector(v_green) & "0000";
  dp_live_video_in_pixel1(11 downto  0) <= std_logic_vector(v_blue)  & "0000";

  -- Keyboard port B charge control (as per the wukong target).
  process (portb_pins, portb_charge_pins) is
  begin
    if portb_charge_pins = '1' then
      portb_pins <= (others => '1');
    else
      portb_pins <= (others => 'Z');
    end if;
    portb_pins_in <= portb_pins;
  end process;

  -- Various processing steps synchronized to the CPU clock.
  process (cpuclock) is
  begin
    if rising_edge(cpuclock) then
      portp_drive <= portp;

      -- The reset_button signal is active low, btncpureset is active low.
      -- Hold the core in reset until the clocks are locked.
      btncpureset <= reset_button and clocks_locked;
    end if;
  end process;

  -- LED on carrier card (active low).
  led <= not portp_drive(4);

end Behavioral;
