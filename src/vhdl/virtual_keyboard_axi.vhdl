--------------------------------------------------------------------------------
-- AXI4-Lite virtual keyboard and joysticks for the KV260.
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
--   0x0C  RW  JOYS    [4:0] joystick A, [12:8] joystick B;
--                       [31:16] reads 0x4A59 ("JY") as a capability tag
--                       bit order up,down,left,right,fire; active low
--
-- Reset values release every key and joystick direction/button, so a
-- freshly-loaded design injects nothing until a daemon writes.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity virtual_keyboard_axi is
  port (
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;

    -- Destination clock for the values exposed to the MEGA65 core.
    core_clk       : in  std_logic;

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

    -- To machine's virtual_to_matrix injector (via new machine ports), already
    -- synchronized into core_clk below.
    virtual_key1 : out unsigned(7 downto 0) := x"FF";
    virtual_key2 : out unsigned(7 downto 0) := x"FF";
    virtual_key3 : out unsigned(7 downto 0) := x"FF";
    virtual_restore : out std_logic := '1';  -- active low, 1 = released

    -- Native active-low joystick vectors consumed by machine's existing
    -- keymapper.  Vector order matches its joya/joyb convention:
    -- 0=up, 1=down, 2=left, 3=right, 4=fire.
    virtual_joya : out std_logic_vector(4 downto 0) := (others => '1');
    virtual_joyb : out std_logic_vector(4 downto 0) := (others => '1')
  );
end virtual_keyboard_axi;

architecture rtl of virtual_keyboard_axi is

  signal keys_reg : std_logic_vector(23 downto 0) := (others => '1'); -- 0xFFFFFF
  signal ctrl_reg : std_logic_vector(0 downto 0)  := "0";
  signal joys_reg : std_logic_vector(9 downto 0) := (others => '1');

  -- Keys are human-speed, quasi-static values, but feeding the AXI-domain
  -- flops directly into the keyboard scanner left metastability paths into
  -- ordinary data, clock-enable, and reset pins.  Synchronize every bit before
  -- it reaches the core.  Only publish a bus after two consecutive core-clock
  -- samples agree, so the scanner never sees a half-updated key code.
  signal keys_meta : std_logic_vector(23 downto 0) := (others => '1');
  signal keys_check : std_logic_vector(23 downto 0) := (others => '1');
  signal keys_core : std_logic_vector(23 downto 0) := (others => '1');
  signal ctrl_meta : std_logic_vector(0 downto 0) := "0";
  signal ctrl_check : std_logic_vector(0 downto 0) := "0";
  signal ctrl_core : std_logic_vector(0 downto 0) := "0";
  signal joys_meta : std_logic_vector(9 downto 0) := (others => '1');
  signal joys_check : std_logic_vector(9 downto 0) := (others => '1');
  signal joys_core : std_logic_vector(9 downto 0) := (others => '1');

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
  attribute ASYNC_REG of keys_meta : signal is "TRUE";
  attribute ASYNC_REG of keys_check : signal is "TRUE";
  attribute ASYNC_REG of ctrl_meta : signal is "TRUE";
  attribute ASYNC_REG of ctrl_check : signal is "TRUE";
  attribute ASYNC_REG of joys_meta : signal is "TRUE";
  attribute ASYNC_REG of joys_check : signal is "TRUE";

begin

  s_axi_awready <= awready_i;
  s_axi_wready  <= wready_i;
  s_axi_bvalid  <= bvalid_i;
  s_axi_bresp   <= "00";
  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  s_axi_rdata   <= rdata_i;
  s_axi_rresp   <= "00";

  -- AW and W are independent AXI-Lite channels.  Hold each until both have
  -- arrived, and accept no new request while its single response slot is busy.
  awready_i <= '1' when aw_held = '0' and bvalid_i = '0' else '0';
  wready_i  <= '1' when w_held  = '0' and bvalid_i = '0' else '0';
  arready_i <= '1' when rvalid_i = '0' else '0';

  virtual_key1    <= unsigned(keys_core(7 downto 0));
  virtual_key2    <= unsigned(keys_core(15 downto 8));
  virtual_key3    <= unsigned(keys_core(23 downto 16));
  virtual_restore <= not ctrl_core(0);   -- CTRL bit0=1 => press => output '0'
  virtual_joya    <= joys_core(4 downto 0);
  virtual_joyb    <= joys_core(9 downto 5);

  process (core_clk)
  begin
    if rising_edge(core_clk) then
      keys_meta <= keys_reg;
      keys_check <= keys_meta;
      ctrl_meta <= ctrl_reg;
      ctrl_check <= ctrl_meta;
      joys_meta <= joys_reg;
      joys_check <= joys_meta;
      if keys_meta = keys_check then
        keys_core <= keys_check;
      end if;
      if ctrl_meta = ctrl_check then
        ctrl_core <= ctrl_check;
      end if;
      if joys_meta = joys_check then
        joys_core <= joys_check;
      end if;
    end if;
  end process;

  process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        keys_reg  <= (others => '1');
        ctrl_reg  <= "0";
        joys_reg  <= (others => '1');
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
              for lane in 0 to 2 loop
                if wr_strb(lane) = '1' then
                  keys_reg(lane * 8 + 7 downto lane * 8) <=
                    wr_data(lane * 8 + 7 downto lane * 8);
                end if;
              end loop;
            when "01" =>
              if wr_strb(0) = '1' then
                ctrl_reg <= wr_data(0 downto 0);
              end if;
            when "11" =>
              if wr_strb(0) = '1' then
                joys_reg(4 downto 0) <= wr_data(4 downto 0);
              end if;
              if wr_strb(1) = '1' then
                joys_reg(9 downto 5) <= wr_data(12 downto 8);
              end if;
            when others => null;
          end case;
          aw_held  <= '0';
          w_held   <= '0';
          bvalid_i <= '1';
        end if;

        if rvalid_i = '1' then
          if s_axi_rready = '1' then
            rvalid_i <= '0';
          end if;
        elsif arready_i = '1' and s_axi_arvalid = '1' then
          case s_axi_araddr(3 downto 2) is
            when "00"   => rdata_i <= x"00" & keys_reg;
            when "01"   => rdata_i <= (0 => ctrl_reg(0), others => '0');
            when "10"   => rdata_i <= x"4D36354B";   -- "M65K"
            when "11"   =>
              rdata_i <= (others => '0');
              rdata_i(4 downto 0) <= joys_reg(4 downto 0);
              rdata_i(12 downto 8) <= joys_reg(9 downto 5);
              rdata_i(31 downto 16) <= x"4A59";       -- "JY"
            when others => rdata_i <= (others => '0');
          end case;
          rvalid_i <= '1';
        end if;
      end if;
    end if;
  end process;

end rtl;
