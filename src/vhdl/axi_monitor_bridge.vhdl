--------------------------------------------------------------------------------
-- AXI4-Lite <-> MEGA65 serial monitor bridge.
--
-- Gives the MEGA65's existing serial monitor a second transport that costs no
-- board pins: a host drives it over JTAG via a jtag_axi master.
--
--   Vivado hw manager --JTAG--> jtag_axi --AXI4-Lite--> this --UART--> monitor
--
-- WHY NOT axi_uartlite: its baud rate is a build-time constant restricted to a
-- table topping out at 230400, and the MEGA65 monitor runs at 2 Mbaud.
-- axi_uart16550 has a runtime divisor but computes it from the AXI clock, and
-- no sensible AXI clock divides to 2.025 MHz exactly.
--
-- So this is a plain UART with a generic divisor, which the instantiating design
-- sets to match whatever the monitor is actually running at. A UART link is
-- asynchronous by nature, so the two ends do not need a common clock -- only
-- matching bit rates within a couple of percent.
--
-- On the KV260 build: the monitor resets its divisor to (40e6/2e6)-1, giving
-- cpuclock/20 = 40.4996 MHz / 20 = 2.02498 Mbaud. This bridge runs from
-- pl_clk0 at 99.999 MHz, so CLOCKS_PER_BIT = 49 gives 2.04080 Mbaud -- 0.78%
-- fast, comfortably inside the ~2% a UART tolerates over a 10-bit frame. Both
-- clocks come from the same MMCM chain, so that offset is fixed, not drifting.
--
-- Register map (AXI4-Lite, 4 words):
--   0x00  W   TX data      write a byte to send to the monitor
--   0x04  R   RX data      read a byte received from the monitor; clears RXVALID
--   0x08  R   STATUS       bit0 TXBUSY, bit1 RXVALID, bit2 RXOVERRUN
--   0x0C  RW  CONTROL      bit0 write 1 to clear RXOVERRUN
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity axi_monitor_bridge is
  generic (
    -- Clocks per bit. Must equal the monitor's (bit_rate_divisor + 1).
    CLOCKS_PER_BIT : integer := 20
  );
  port (
    -- AXI4-Lite slave
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

    -- To/from the MEGA65 monitor's UART
    uart_tx : out std_logic := '1';   -- into the monitor's RsRx
    uart_rx : in  std_logic           -- from the monitor's UART_TXD
  );
end axi_monitor_bridge;

architecture rtl of axi_monitor_bridge is

  -- Transmit
  type tx_state_t is (TX_IDLE, TX_SEND);
  signal tx_state   : tx_state_t := TX_IDLE;
  signal tx_shift   : std_logic_vector(9 downto 0) := (others => '1');
  signal tx_bitcnt  : integer range 0 to 10 := 0;
  signal tx_clkcnt  : integer range 0 to CLOCKS_PER_BIT-1 := 0;
  signal tx_busy    : std_logic := '0';

  -- Receive
  type rx_state_t is (RX_IDLE, RX_START, RX_DATABITS, RX_STOP);
  signal rx_state   : rx_state_t := RX_IDLE;
  signal rx_shift   : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_bitcnt  : integer range 0 to 8 := 0;
  signal rx_clkcnt  : integer range 0 to CLOCKS_PER_BIT-1 := 0;
  signal rx_byte    : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_valid   : std_logic := '0';
  signal rx_overrun : std_logic := '0';
  signal rx_sync    : std_logic_vector(2 downto 0) := (others => '1');

  -- AXI handshake
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

  process (s_axi_aclk)
    variable do_write : boolean;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        tx_state   <= TX_IDLE;
        tx_busy    <= '0';
        uart_tx    <= '1';
        rx_state   <= RX_IDLE;
        rx_valid   <= '0';
        rx_overrun <= '0';
        awready_i  <= '0';
        wready_i   <= '0';
        bvalid_i   <= '0';
        arready_i  <= '0';
        rvalid_i   <= '0';
        rx_sync    <= (others => '1');
      else

        ----------------------------------------------------------------------
        -- UART transmit
        ----------------------------------------------------------------------
        case tx_state is
          when TX_IDLE =>
            uart_tx <= '1';
          when TX_SEND =>
            uart_tx <= tx_shift(0);
            if tx_clkcnt = CLOCKS_PER_BIT-1 then
              tx_clkcnt <= 0;
              tx_shift  <= '1' & tx_shift(9 downto 1);
              if tx_bitcnt = 9 then
                tx_state <= TX_IDLE;
                tx_busy  <= '0';
              else
                tx_bitcnt <= tx_bitcnt + 1;
              end if;
            else
              tx_clkcnt <= tx_clkcnt + 1;
            end if;
        end case;

        ----------------------------------------------------------------------
        -- UART receive (start bit, 8 data, stop; sampled mid-bit)
        ----------------------------------------------------------------------
        rx_sync <= rx_sync(1 downto 0) & uart_rx;
        case rx_state is
          when RX_IDLE =>
            if rx_sync(2) = '0' then          -- start bit edge
              rx_clkcnt <= 0;
              rx_state  <= RX_START;
            end if;
          when RX_START =>
            if rx_clkcnt = (CLOCKS_PER_BIT-1)/2 then
              if rx_sync(2) = '0' then        -- still low: genuine start
                rx_clkcnt <= 0;
                rx_bitcnt <= 0;
                rx_state  <= RX_DATABITS;
              else
                rx_state <= RX_IDLE;          -- glitch
              end if;
            else
              rx_clkcnt <= rx_clkcnt + 1;
            end if;
          when RX_DATABITS =>
            if rx_clkcnt = CLOCKS_PER_BIT-1 then
              rx_clkcnt <= 0;
              rx_shift  <= rx_sync(2) & rx_shift(7 downto 1);
              if rx_bitcnt = 7 then
                rx_state <= RX_STOP;
              else
                rx_bitcnt <= rx_bitcnt + 1;
              end if;
            else
              rx_clkcnt <= rx_clkcnt + 1;
            end if;
          when RX_STOP =>
            if rx_clkcnt = CLOCKS_PER_BIT-1 then
              rx_clkcnt <= 0;
              rx_state  <= RX_IDLE;
              rx_byte   <= rx_shift;
              if rx_valid = '1' then
                rx_overrun <= '1';            -- host did not keep up
              end if;
              rx_valid <= '1';
            else
              rx_clkcnt <= rx_clkcnt + 1;
            end if;
        end case;

        ----------------------------------------------------------------------
        -- AXI4-Lite write
        ----------------------------------------------------------------------
        do_write := false;
        if awready_i = '0' and s_axi_awvalid = '1' then
          awready_i <= '1';
          wr_addr   <= s_axi_awaddr;
        else
          awready_i <= '0';
        end if;

        if wready_i = '0' and s_axi_wvalid = '1' then
          wready_i <= '1';
          do_write := true;
        else
          wready_i <= '0';
        end if;

        if do_write then
          case wr_addr(3 downto 2) is
            when "00" =>                       -- 0x00 TX data
              if tx_state = TX_IDLE then
                tx_shift  <= '1' & s_axi_wdata(7 downto 0) & '0';  -- stop,data,start
                tx_bitcnt <= 0;
                tx_clkcnt <= 0;
                tx_busy   <= '1';
                tx_state  <= TX_SEND;
              end if;
            when "11" =>                       -- 0x0C CONTROL
              if s_axi_wdata(0) = '1' then
                rx_overrun <= '0';
              end if;
            when others => null;
          end case;
          bvalid_i <= '1';
        elsif bvalid_i = '1' and s_axi_bready = '1' then
          bvalid_i <= '0';
        end if;

        ----------------------------------------------------------------------
        -- AXI4-Lite read
        ----------------------------------------------------------------------
        if arready_i = '0' and s_axi_arvalid = '1' then
          arready_i <= '1';
          rdata_i   <= (others => '0');
          case s_axi_araddr(3 downto 2) is
            when "01" =>                       -- 0x04 RX data
              rdata_i(7 downto 0) <= rx_byte;
              rx_valid <= '0';
            when "10" =>                       -- 0x08 STATUS
              rdata_i(0) <= tx_busy;
              rdata_i(1) <= rx_valid;
              rdata_i(2) <= rx_overrun;
            when others => null;
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
