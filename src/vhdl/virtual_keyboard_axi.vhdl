--------------------------------------------------------------------------------
-- AXI4-Lite virtual keyboard for the KV260.
--
-- The KV260 has no pins for the CIA1 keyboard matrix, so keys are injected from
-- the PS instead. This slave holds up to three simultaneous MEGA65 keyboard
-- matrix positions; a userspace daemon on the PS (driven from an SSH terminal)
-- writes them, and they feed the core's existing virtual_to_matrix injector via
-- machine's virtual_key1/2/3 inputs.
--
-- Encoding matches virtual_to_matrix: each key byte is a matrix position 0..71;
-- any value > 71 (use 0xFF) means "no key". So three keys = three-key rollover,
-- which is enough for a retro machine (a normal key + two modifiers).
--
-- Register map (AXI4-Lite):
--   0x00  RW  KEYS    [7:0] key1, [15:8] key2, [23:16] key3   (each 0xFF=none)
--   0x04  RW  CTRL    [0] restore (1=press RESTORE)           (optional)
--   0x08  R   MAGIC   returns 0x4D36354B ("M65K") for probing
--
-- Reset value of KEYS is 0xFFFFFF (all released), so a freshly-loaded design
-- injects nothing until the daemon writes.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity virtual_keyboard_axi is
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

    -- To machine's virtual_to_matrix injector (via new machine ports).
    -- cpuclock domain in the core; these are steady register values, and the
    -- injector re-samples them, so a plain CDC of stable bytes is safe.
    virtual_key1 : out unsigned(7 downto 0) := x"FF";
    virtual_key2 : out unsigned(7 downto 0) := x"FF";
    virtual_key3 : out unsigned(7 downto 0) := x"FF";
    virtual_restore : out std_logic := '1'   -- active low, 1 = released
  );
end virtual_keyboard_axi;

architecture rtl of virtual_keyboard_axi is

  signal keys_reg : std_logic_vector(23 downto 0) := (others => '1'); -- 0xFFFFFF
  signal ctrl_reg : std_logic_vector(0 downto 0)  := "0";

  signal awready_i : std_logic := '0';
  signal wready_i  : std_logic := '0';
  signal bvalid_i  : std_logic := '0';
  signal arready_i : std_logic := '0';
  signal rvalid_i  : std_logic := '0';
  signal rdata_i   : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_addr   : std_logic_vector(3 downto 0) := (others => '0');

begin

  s_axi_awready <= awready_i;
  s_axi_wready  <= wready_i;
  s_axi_bvalid  <= bvalid_i;
  s_axi_bresp   <= "00";
  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  s_axi_rdata   <= rdata_i;
  s_axi_rresp   <= "00";

  virtual_key1    <= unsigned(keys_reg(7 downto 0));
  virtual_key2    <= unsigned(keys_reg(15 downto 8));
  virtual_key3    <= unsigned(keys_reg(23 downto 16));
  virtual_restore <= not ctrl_reg(0);   -- CTRL bit0=1 => press => output '0'

  process (s_axi_aclk)
    variable do_write : boolean;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        keys_reg  <= (others => '1');
        ctrl_reg  <= "0";
        awready_i <= '0';
        wready_i  <= '0';
        bvalid_i  <= '0';
        arready_i <= '0';
        rvalid_i  <= '0';
      else
        -- write address
        if awready_i = '0' and s_axi_awvalid = '1' then
          awready_i <= '1';
          wr_addr   <= s_axi_awaddr;
        else
          awready_i <= '0';
        end if;

        -- write data
        do_write := false;
        if wready_i = '0' and s_axi_wvalid = '1' then
          wready_i <= '1';
          do_write := true;
        else
          wready_i <= '0';
        end if;

        if do_write then
          case wr_addr(3 downto 2) is
            when "00" => keys_reg <= s_axi_wdata(23 downto 0);
            when "01" => ctrl_reg <= s_axi_wdata(0 downto 0);
            when others => null;
          end case;
          bvalid_i <= '1';
        elsif bvalid_i = '1' and s_axi_bready = '1' then
          bvalid_i <= '0';
        end if;

        -- read
        if arready_i = '0' and s_axi_arvalid = '1' then
          arready_i <= '1';
          case s_axi_araddr(3 downto 2) is
            when "00"   => rdata_i <= x"00" & keys_reg;
            when "01"   => rdata_i <= (0 => ctrl_reg(0), others => '0');
            when "10"   => rdata_i <= x"4D36354B";   -- "M65K"
            when others => rdata_i <= (others => '0');
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
