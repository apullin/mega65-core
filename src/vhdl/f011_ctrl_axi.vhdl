--------------------------------------------------------------------------------
-- AXI4-Lite control for F011 floppy virtualisation, for the KV260.
--
-- WHY THIS EXISTS
--
-- Virtualisation is enabled by $D659.0, and gs4510 gates that write on
-- hypervisor_mode='1'.  That is silicon, not a permission: no amount of memory
-- access from outside lets a host set it.  The workaround that does work is to
-- halt the CPU inside hyppo and make it *execute* the store (see
-- tools/m65-fd-enable), which is effective but is a debugger trick sitting on
-- the critical path of an ordinary feature.
--
-- The underlying mismatch is that hyppo was written for a machine where the
-- only outside agent is a debug cable.  On this board a full Linux system sits
-- alongside the core and is the natural place for disk images to live.  So
-- rather than tunnelling through a debug protocol, this exposes the same
-- controls directly, the way vkbd / dpaud / mon_uart already do.
--
-- What comes out of here is OR-ed with the CPU's own virtualised_hardware, so
-- the hypervisor path keeps working exactly as before -- this only adds a
-- second way to assert the same thing, and cannot take it away.
--
-- Register map (AXI4-Lite):
--   0x00  RW  CTRL   [0] virtualise drive 0
--                    [1] virtualise drive 1
--                    [2] drive 0 media present
--                    [3] drive 1 media present
--                    [4] drive 0 image is a 1541 (.d64) rather than a 1581
--                    [5] drive 1 image is a 1541
--                    [6] drive 0 write protected
--                    [7] drive 1 write protected
--   0x04  W   EVENT  [0] write 1 to pulse "disk has been changed" at the core,
--                        so the guest re-reads the BAM after a swap.  Reads
--                        back the last value written.
--   0x08  R   MAGIC  0x4D363546 ("M65F")
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity f011_ctrl_axi is
  port (
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;

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

    -- to the core, in the core's clock domain
    core_clk      : in  std_logic;
    -- One bus rather than two bits, so the block design carries a single port.
    virt_drive0_bus : out std_logic_vector(1 downto 0) := "00";
    media_present_bus : out std_logic_vector(1 downto 0) := "00";
    d64_bus       : out std_logic_vector(1 downto 0) := "00";
    write_protect_bus : out std_logic_vector(1 downto 0) := "00";
    disk_changed  : out std_logic := '0'    -- one core_clk pulse
  );
end f011_ctrl_axi;

architecture rtl of f011_ctrl_axi is

  signal ctrl_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal event_reg : std_logic_vector(0 downto 0) := "0";

  -- CTRL is written by a human and then sits still, so a two-flop sync per bit
  -- is honest: there is no instant at which a coherent multi-bit update matters.
  signal ctrl_meta, ctrl_core : std_logic_vector(7 downto 0) := (others => '0');

  -- The disk-change event is a toggle across the domain rather than a level,
  -- so a pulse cannot be missed or stretched by the clock ratio.
  signal chg_tog  : std_logic := '0';
  signal chg_sync : std_logic_vector(2 downto 0) := (others => '0');

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

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of ctrl_meta : signal is "TRUE";
  attribute ASYNC_REG of ctrl_core : signal is "TRUE";
  attribute ASYNC_REG of chg_sync : signal is "TRUE";

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

  virt_drive0_bus <= ctrl_core(1 downto 0);
  media_present_bus <= ctrl_core(3 downto 2);
  d64_bus <= ctrl_core(5) & ctrl_core(4);
  write_protect_bus <= ctrl_core(7 downto 6);

  process (core_clk)
  begin
    if rising_edge(core_clk) then
      ctrl_meta <= ctrl_reg;
      ctrl_core <= ctrl_meta;
      chg_sync  <= chg_sync(1 downto 0) & chg_tog;
      if chg_sync(2) /= chg_sync(1) then
        disk_changed <= '1';
      else
        disk_changed <= '0';
      end if;
    end if;
  end process;

  process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        ctrl_reg  <= (others => '0');
        event_reg <= "0";
        chg_tog   <= '0';
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
                event_reg <= wr_data(0 downto 0);
                if wr_data(0) = '1' then
                  chg_tog <= not chg_tog;
                end if;
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
            when "01"   => rdata_i <= (0 => event_reg(0), others => '0');
            when "10"   => rdata_i <= x"4D363546";     -- "M65F"
            when others => rdata_i <= (others => '0');
          end case;
          rvalid_i <= '1';
        end if;
      end if;
    end if;
  end process;

end rtl;
