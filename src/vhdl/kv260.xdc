##############################################################################
## MEGA65 on the AMD/Xilinx Kria KV260 Vision AI Starter Kit (XCK26).
##
## PROVENANCE OF THESE PIN NUMBERS
##
## The package pins below are derived by chaining two files from AMD's own
## board store (github.com/Xilinx/XilinxBoardStore):
##
##   boards/Xilinx/kv260_carrier/1.3/board.xml   connector index -> som240_1_*
##   boards/Xilinx/kv260_som/1.4/part0_pins.xml  som240_1_*      -> package pin
##
## These eleven signals are the complete set of PL-accessible LVCMOS33 I/O that
## the KV260 carrier card brings out.  In AMD's own reference designs they carry
## the I2S audio PMOD (UG1089 documents an audio codec PMOD on J2) and a small
## GPIO group.
##
## WHAT IS NOT ESTABLISHED: which physical pin of the Pmod header (J2) each of
## these lands on.  UG1089 defers Pmod pin assignment to the carrier card
## schematic, and the board files describe the connector only by index.  So the
## design below will build and the FPGA pins are correct, but before wiring up
## an SD card breakout you must check the KV260 carrier schematic to find which
## J2 pin corresponds to which som240_1_* signal.  Do not guess at that.
##
## Bank 45 is a 3.3 V HD bank, so LVCMOS33 throughout.
##############################################################################

## ---------------------------------------------------------------------------
## Clock.  In the assembled design clk_in is PS pl_clk0 and is NOT a package
## pin -- this constraint exists for out-of-context runs.  Comment it out once
## the PS block design drives the clock.
## ---------------------------------------------------------------------------
create_clock -period 10.000 -name clk_in [get_ports clk_in]

## ---------------------------------------------------------------------------
## PULLUPs on every input.
##
## This matters more than it looks. reset_button is active low and feeds
## btncpureset directly; with nothing wired to F11 the pin floats, and if it
## floats low the core sits in reset forever and the board looks dead. rsrx and
## sd_miso want to idle high for the same reason (a floating UART receive line
## reads as a break condition).
##
## With these pulls the design boots correctly with NOTHING attached to any PL
## pin -- just 12V, an HDMI cable and USB-JTAG.
## ---------------------------------------------------------------------------

## ---------------------------------------------------------------------------
## SD card, SPI mode
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports sd_reset] ;# som240_1_b21
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33} [get_ports sd_clock] ;# som240_1_b22
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports sd_mosi]  ;# som240_1_c22
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports sd_miso] ;# som240_1_d20

## ---------------------------------------------------------------------------
## Serial monitor UART
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_txd] ;# som240_1_d21
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports rsrx] ;# som240_1_d22

## ---------------------------------------------------------------------------
## Audio (PWM) and status
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS33} [get_ports pwm_l]        ;# som240_1_d18
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS33} [get_ports pwm_r]        ;# som240_1_b17
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports led]          ;# som240_1_b18
set_property -dict {PACKAGE_PIN F11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports reset_button] ;# som240_1_a15
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports restore_key] ;# som240_1_c24

## ---------------------------------------------------------------------------
## Keyboard (CIA1 matrix) has no pins on this board.
##
## porta_pins / portb_pins are 8 bits each; the carrier exposes only the eleven
## signals above and they are all spoken for.  A real keyboard therefore needs
## either a serialised PMOD keyboard adapter or a PS-side USB HID bridge writing
## the matrix over AXI.  Until then these remain unconstrained and the design is
## only valid for out-of-context runs.
## ---------------------------------------------------------------------------

## ---------------------------------------------------------------------------
## Video goes to the PS DisplayPort controller's live-video input, not to pins.
## See kv260_ps_bd.tcl.  dp_video_in_clk is generated in the PL (27 MHz) and is
## an input TO the PS.
## ---------------------------------------------------------------------------

## ---------------------------------------------------------------------------
## Remote keyboard clock crossing.
##
## The virtual keyboard's three "currently pressed" matrix positions are written
## by the PS on the 100 MHz AXI clock and read by the core on its 40.5 MHz
## clock, with no synchroniser.  That is deliberate: a key is held down for tens
## of milliseconds while the core rescans the matrix at 1 kHz, so the value is
## quasi-static and a setup check against a specific 40.5 MHz edge means
## nothing.  Left unconstrained the tool reports ~90 failing endpoints here and
## nowhere else, which buries any real violation.
##
## Bound the datapath rather than declaring a false path: that still holds
## bit-to-bit skew well under a scan interval, so a scan can never latch a
## half-updated position and synthesise a key nobody pressed.
## ---------------------------------------------------------------------------
## Kept as a single flat statement on purpose.  Wrapping this in an "if" that
## checked the cells existed looked safer but was not: Vivado rewrites XDC when
## it propagates constraints from synthesis to implementation, and the rewritten
## if/else silently failed to apply the exception -- the build still reported
## all 90 endpoints failing.  Applying the identical set_max_delay by hand to
## the routed checkpoint gave slack +1.899 with requirement 10.000, which is how
## the flat form was confirmed to be the working one.  During synthesis the
## block design is a black box so this matches nothing and merely warns; at
## implementation it matches the 24 key registers.
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *vkbd/inst/keys_reg_reg*}]


## ---------------------------------------------------------------------------
## The DisplayPort audio reference clock.
##
## dp_audio_ref_clk comes out of the PS and clocks the audio stream master, but
## the tool has no way to know its period, so without this the whole audio
## domain is simply *not analysed* -- which reads as "0 failing endpoints" and
## is not the same thing as passing.  Measured on the board it is 24,575,995 Hz,
## i.e. 24.576 MHz, the canonical 512 x 48000 audio master clock.  (Vivado's
## board preset claims 24.242 MHz for this output; the driver reprograms it, so
## the hardware is the authority.)
create_clock -period 40.690 -name dp_audio_ref_clk \
    [get_pins -quiet -hier -filter {NAME =~ *dpaud/inst/bufg_aud/O}]

## Audio clock crossings.
##
## dp_audio_axis deliberately spans three domains: AXI-Lite config on the
## interconnect's 100 MHz clock, the stream on the 24.2 MHz DisplayPort audio
## reference clock, and the core's mixer on the 40.5 MHz CPU clock.  Every
## crossing below is either a two-flop synchroniser or the sample handshake,
## both of which the timing engine has no way to recognise on its own -- left
## alone it reports the sample bus as ~33 failing endpoints.
##
## Bounded rather than false-pathed, for the same reason as the keyboard: the
## captured stereo pair must not skew across a sampling instant, or left and
## right would come from different moments and the audio would click.
##
## Flat statements, not wrapped in a existence check -- see the note above about
## Vivado rewriting conditional XDC during constraint propagation.
## ---------------------------------------------------------------------------
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/cap_*_reg*}]
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/req_tog_reg*}]
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/ack_tog_reg*}]
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/ctrl_reg_reg*}]
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/div_reg_reg*}]
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/frames_reg*}]
set_max_delay -datapath_only 10.000 -from [get_cells -quiet -hier -filter {NAME =~ *dpaud/inst/stalls_reg*}]
