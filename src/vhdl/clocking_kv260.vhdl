----------------------------------------------------------------------------------
-- Clock generation for the Xilinx Kria KV260 (XCK26, Zynq UltraScale+).
--
-- UltraScale+ counterpart of clocking50mhz.vhdl. The rest of the core sees
-- exactly the frequencies it already expects.
--
--   pl_clk0 99.999 MHz x 10.125 = 1012.49 MHz VCO   (stage 1)
--   1012.49 MHz / 10            =  101.249 MHz      (stage 1 output)
--   101.249 MHz x 12            = 1214.99 MHz VCO   (stage 2)
--
--   1215 / 7.5 = 162    MHz
--   1215 / 9   = 135    MHz
--   1215 / 15  =  81    MHz   (pixelclock)
--   1215 / 30  =  40.5  MHz   (cpuclock)
--   1215 / 45  =  27    MHz   (true pixel clock / video timing)
--
-- A separate MMCM makes 74.226 MHz directly from pl_clk0 for the core's
-- existing 720p upscaler: 99.999 MHz x 9 / 12.125.  Keeping it separate avoids
-- perturbing the timing-closed 27/40.5/81/162 MHz core clock set.
--
-- All land within 0.001% of nominal (27 MHz comes out as 26.99973 MHz).
--
-- WHY THE STAGE-2 MULTIPLIER IS 12 AND NOT 8
--
-- The 7-series original uses an 810 MHz VCO, which divides beautifully by
-- 30/20/10 to give 27/40.5/81. It is tempting to keep it. Do not.
--
-- The MMCME4 VCO floor on this device is 800 MHz, so an 810 MHz VCO has only
-- 10 MHz of margin. That is not enough to survive the input clock being even
-- slightly off nominal -- and it will be, because the PS cannot produce
-- arbitrary frequencies exactly. This bit me: an earlier version of this file
-- used x8, placed and routed and met timing, and then failed bitstream DRC:
--
--   ERROR: [DRC PDRC-179] The computed value 785.493 MHz for the VCO operating
--   frequency of the MMCM site ... falls outside the operating range
--   (800.000 - 1600.000 MHz)
--
-- ...because pl_clk0 was actually 96.97 MHz, not 100 MHz. Two lessons, both
-- now handled: apply the KV260 board preset so the PS reference clock is right
-- (see kv260_full.tcl), and leave real margin on the VCO. x12 gives 415 MHz of
-- it while keeping every output on an exact integer divider.
--
-- Other differences from MMCME2_ADV:
--   * port list adds CDDCREQ/CDDCDONE, tied off here
--   * COMPENSATION "ZHOLD" is 7-series only; UltraScale+ uses "AUTO"
--
-- There is no clock270/clock324 here, unlike the 7-series version: those exist
-- to clock the 10:1 TMDS serialisers, and this board has no PL video pins.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use IEEE.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity clocking_kv260 is
  port (
    -- ~100 MHz reference from the PS (pl_clk0).
    clk_in    : in  std_logic;

    clock27   : out std_logic;
    clock41   : out std_logic;
    clock81p  : out std_logic;
    clock81n  : out std_logic;
    clock135p : out std_logic;
    clock135n : out std_logic;
    clock162  : out std_logic;
    clock74p22 : out std_logic;

    locked    : out std_logic
  );
end entity;

architecture RTL of clocking_kv260 is

  signal clk_fb_adjust0 : std_logic := '0';
  signal clk_fb         : std_logic := '0';
  signal clock10125mhz  : std_logic := '0';
  signal clock27_unbuffered : std_logic := '0';
  signal clock74p22_unbuffered : std_logic := '0';

  signal locked_stage1  : std_logic := '0';
  signal locked_stage2  : std_logic := '0';
  signal locked_720p    : std_logic := '0';
  signal clk_fb_720p    : std_logic := '0';

  -- The downstream display mux deliberately consumes these global-buffer
  -- outputs.  Prevent clock optimization from bypassing either buffer and
  -- recreating an illegal cross-region MMCM-to-BUFGCTRL connection.
  attribute dont_touch : string;
  attribute dont_touch of clock27_buf : label is "true";
  attribute dont_touch of clock74p22_buf : label is "true";

begin

  -- Stage 1: ~100 MHz -> 101.249 MHz (VCO 1012.49 MHz)
  adjust0 : MMCME4_ADV
    generic map (
      BANDWIDTH            => "OPTIMIZED",
      CLKOUT4_CASCADE      => "FALSE",
      COMPENSATION         => "AUTO",
      STARTUP_WAIT         => "FALSE",

      CLKIN1_PERIOD        => 10.000,   -- 100 MHz nominal

      DIVCLK_DIVIDE        => 1,
      CLKFBOUT_MULT_F      => 10.125,
      CLKFBOUT_PHASE       => 0.000,
      CLKFBOUT_USE_FINE_PS => "FALSE",

      CLKOUT0_DIVIDE_F     => 10.000,
      CLKOUT0_PHASE        => 0.000,
      CLKOUT0_DUTY_CYCLE   => 0.500,
      CLKOUT0_USE_FINE_PS  => "FALSE",

      REF_JITTER1          => 0.010
    )
    port map (
      CLKFBOUT  => clk_fb_adjust0,
      CLKOUT0   => clock10125mhz,
      LOCKED    => locked_stage1,

      CLKFBIN   => clk_fb_adjust0,
      CLKIN1    => clk_in,
      CLKIN2    => '0',
      CLKINSEL  => '1',

      DADDR     => (others => '0'),
      DCLK      => '0',
      DEN       => '0',
      DI        => (others => '0'),
      DWE       => '0',

      PSCLK     => '0',
      PSEN      => '0',
      PSINCDEC  => '0',

      CDDCREQ   => '0',

      PWRDWN    => '0',
      RST       => '0'
    );

  -- Stage 2: 101.249 MHz -> the core's clock set (VCO 1214.99 MHz)
  mmcm_adv0 : MMCME4_ADV
    generic map (
      BANDWIDTH            => "OPTIMIZED",
      CLKOUT4_CASCADE      => "FALSE",
      COMPENSATION         => "AUTO",
      STARTUP_WAIT         => "FALSE",

      CLKIN1_PERIOD        => 9.8766,   -- 101.249 MHz

      DIVCLK_DIVIDE        => 1,
      CLKFBOUT_MULT_F      => 12.000,   -- 101.249 x 12 = 1214.99 MHz VCO
      CLKFBOUT_PHASE       => 0.000,
      CLKFBOUT_USE_FINE_PS => "FALSE",

      -- clock162 = 1215 / 7.5  (only CLKOUT0 supports fractional division)
      CLKOUT0_DIVIDE_F     => 7.500,
      CLKOUT0_PHASE        => 0.000,
      CLKOUT0_DUTY_CYCLE   => 0.500,
      CLKOUT0_USE_FINE_PS  => "FALSE",

      -- clock135 = 1215 / 9
      CLKOUT1_DIVIDE       => 9,
      CLKOUT1_PHASE        => 0.000,
      CLKOUT1_DUTY_CYCLE   => 0.500,
      CLKOUT1_USE_FINE_PS  => "FALSE",

      -- clock81 = 1215 / 15  (pixelclock)
      CLKOUT2_DIVIDE       => 15,
      CLKOUT2_PHASE        => 0.000,
      CLKOUT2_DUTY_CYCLE   => 0.500,
      CLKOUT2_USE_FINE_PS  => "FALSE",

      -- clock41 = 1215 / 30 = 40.5 MHz  (cpuclock)
      CLKOUT3_DIVIDE       => 30,
      CLKOUT3_PHASE        => 0.000,
      CLKOUT3_DUTY_CYCLE   => 0.500,
      CLKOUT3_USE_FINE_PS  => "FALSE",

      -- clock27 = 1215 / 45  (video timing)
      CLKOUT4_DIVIDE       => 45,
      CLKOUT4_PHASE        => 0.000,
      CLKOUT4_DUTY_CYCLE   => 0.500,
      CLKOUT4_USE_FINE_PS  => "FALSE",

      REF_JITTER1          => 0.010
    )
    port map (
      CLKFBOUT  => clk_fb,
      CLKOUT0   => clock162,
      CLKOUT1   => clock135p,
      CLKOUT1B  => clock135n,
      CLKOUT2   => clock81p,
      CLKOUT2B  => clock81n,
      CLKOUT3   => clock41,
      CLKOUT4   => clock27_unbuffered,
      LOCKED    => locked_stage2,

      CLKFBIN   => clk_fb,
      CLKIN1    => clock10125mhz,
      CLKIN2    => '0',
      CLKINSEL  => '1',

      DADDR     => (others => '0'),
      DCLK      => '0',
      DEN       => '0',
      DI        => (others => '0'),
      DWE       => '0',

      PSCLK     => '0',
      PSEN      => '0',
      PSINCDEC  => '0',

      CDDCREQ   => '0',

      PWRDWN    => '0',
      RST       => '0'
    );

  -- Independent 720p pixel clock.  The historical upscaler was tuned around
  -- 74.2268 MHz, so preserve that frequency rather than silently changing its
  -- PAL/NTSC frame-lock compensation to nominal 74.250 MHz.
  mmcm_720p : MMCME4_ADV
    generic map (
      BANDWIDTH            => "OPTIMIZED",
      CLKOUT4_CASCADE      => "FALSE",
      COMPENSATION         => "AUTO",
      STARTUP_WAIT         => "FALSE",

      CLKIN1_PERIOD        => 10.000,
      DIVCLK_DIVIDE        => 1,
      CLKFBOUT_MULT_F      => 9.000,
      CLKFBOUT_PHASE       => 0.000,
      CLKFBOUT_USE_FINE_PS => "FALSE",

      CLKOUT0_DIVIDE_F     => 12.125,
      CLKOUT0_PHASE        => 0.000,
      CLKOUT0_DUTY_CYCLE   => 0.500,
      CLKOUT0_USE_FINE_PS  => "FALSE",

      REF_JITTER1          => 0.010
    )
    port map (
      CLKFBOUT  => clk_fb_720p,
      CLKOUT0   => clock74p22_unbuffered,
      LOCKED    => locked_720p,

      CLKFBIN   => clk_fb_720p,
      CLKIN1    => clk_in,
      CLKIN2    => '0',
      CLKINSEL  => '1',

      DADDR     => (others => '0'),
      DCLK      => '0',
      DEN       => '0',
      DI        => (others => '0'),
      DWE       => '0',

      PSCLK     => '0',
      PSEN      => '0',
      PSINCDEC  => '0',

      CDDCREQ   => '0',

      PWRDWN    => '0',
      RST       => '0'
    );

  -- Explicit source buffers serve both the core logic and the downstream
  -- DisplayPort BUFGCTRL.  A BUFG-to-BUFGCTRL cascade is legal across clock
  -- regions; connecting two MMCMs directly to one BUFGCTRL is not, because
  -- both direct inputs would have to originate in that buffer's one region.
  clock27_buf : BUFGCE
    generic map (SIM_DEVICE => "ULTRASCALE_PLUS")
    port map (I => clock27_unbuffered, CE => '1', O => clock27);

  clock74p22_buf : BUFGCE
    generic map (SIM_DEVICE => "ULTRASCALE_PLUS")
    port map (I => clock74p22_unbuffered, CE => '1', O => clock74p22);

  locked <= locked_stage1 and locked_stage2 and locked_720p;

end RTL;
