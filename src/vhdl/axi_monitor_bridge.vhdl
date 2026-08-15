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
--   0x04  R   RX data      pop one byte received from the monitor
--   0x08  R   STATUS       bit0 TXBUSY, bit1 RXVALID, bit2 RXOVERRUN,
--                         bits31:16 queued RX byte count
--   0x0C  RW  CONTROL      bit0 write 1 to clear RXOVERRUN
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity axi_monitor_bridge is
  generic (
    -- Clocks per bit. Must equal the monitor's (bit_rate_divisor + 1).
    CLOCKS_PER_BIT : integer := 20;
    -- A complete monitor dump can be hundreds of bytes.  Buffer one whole
    -- burst in fabric so Linux scheduling latency cannot lose protocol bytes.
    RX_FIFO_DEPTH : positive := 1024
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
  signal rx_overrun : std_logic := '0';
  signal rx_sync    : std_logic_vector(2 downto 0) := (others => '1');
  type rx_fifo_t is array (natural range <>) of std_logic_vector(7 downto 0);
  signal rx_fifo    : rx_fifo_t(0 to RX_FIFO_DEPTH-1);
  signal rx_read_ptr  : integer range 0 to RX_FIFO_DEPTH-1 := 0;
  signal rx_write_ptr : integer range 0 to RX_FIFO_DEPTH-1 := 0;
  signal rx_count     : integer range 0 to RX_FIFO_DEPTH := 0;

  -- AXI handshake
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
  attribute ASYNC_REG of rx_sync : signal is "TRUE";

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

  process (s_axi_aclk)
    variable rx_push_now      : boolean;
    variable rx_pop_now       : boolean;
    variable rx_push_accepted : boolean;
    variable rx_push_byte     : std_logic_vector(7 downto 0);
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        tx_state   <= TX_IDLE;
        tx_busy    <= '0';
        uart_tx    <= '1';
        rx_state   <= RX_IDLE;
        rx_overrun <= '0';
        rx_read_ptr  <= 0;
        rx_write_ptr <= 0;
        rx_count     <= 0;
        aw_held    <= '0';
        w_held     <= '0';
        bvalid_i   <= '0';
        rvalid_i   <= '0';
        rx_sync    <= (others => '1');
      else
        rx_push_now := false;
        rx_push_byte := (others => '0');
        rx_pop_now := arready_i = '1' and s_axi_arvalid = '1' and
                      s_axi_araddr(3 downto 2) = "01" and rx_count > 0;

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
              rx_push_now := true;
              rx_push_byte := rx_shift;
            else
              rx_clkcnt <= rx_clkcnt + 1;
            end if;
        end case;

        ----------------------------------------------------------------------
        -- AXI4-Lite write
        ----------------------------------------------------------------------
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
            when "00" =>                       -- 0x00 TX data
              if wr_strb(0) = '1' and tx_state = TX_IDLE then
                tx_shift  <= '1' & wr_data(7 downto 0) & '0';  -- stop,data,start
                tx_bitcnt <= 0;
                tx_clkcnt <= 0;
                tx_busy   <= '1';
                tx_state  <= TX_SEND;
              end if;
            when "11" =>                       -- 0x0C CONTROL
              if wr_strb(0) = '1' and wr_data(0) = '1' then
                rx_overrun <= '0';
              end if;
            when others => null;
          end case;
          aw_held   <= '0';
          w_held    <= '0';
          bvalid_i <= '1';
        end if;

        ----------------------------------------------------------------------
        -- AXI4-Lite read
        ----------------------------------------------------------------------
        if rvalid_i = '1' then
          if s_axi_rready = '1' then
            rvalid_i <= '0';
          end if;
        elsif arready_i = '1' and s_axi_arvalid = '1' then
          rdata_i   <= (others => '0');
          case s_axi_araddr(3 downto 2) is
            when "01" =>                       -- 0x04 RX data
              if rx_count > 0 then
                rdata_i(7 downto 0) <= rx_fifo(rx_read_ptr);
              end if;
            when "10" =>                       -- 0x08 STATUS
              rdata_i(0) <= tx_busy;
              if rx_count > 0 then
                rdata_i(1) <= '1';
              else
                rdata_i(1) <= '0';
              end if;
              rdata_i(2) <= rx_overrun;
              rdata_i(31 downto 16) <=
                std_logic_vector(to_unsigned(rx_count, 16));
            when others => null;
          end case;
          rvalid_i <= '1';
        end if;

        ----------------------------------------------------------------------
        -- Receive FIFO update.  Pop and push may happen on the same clock;
        -- when full, that simultaneous exchange is still lossless.
        ----------------------------------------------------------------------
        rx_push_accepted := rx_push_now and
                            (rx_count < RX_FIFO_DEPTH or rx_pop_now);

        if rx_pop_now then
          if rx_read_ptr = RX_FIFO_DEPTH-1 then
            rx_read_ptr <= 0;
          else
            rx_read_ptr <= rx_read_ptr + 1;
          end if;
        end if;

        if rx_push_accepted then
          rx_fifo(rx_write_ptr) <= rx_push_byte;
          if rx_write_ptr = RX_FIFO_DEPTH-1 then
            rx_write_ptr <= 0;
          else
            rx_write_ptr <= rx_write_ptr + 1;
          end if;
        elsif rx_push_now then
          rx_overrun <= '1';
        end if;

        if rx_push_accepted and not rx_pop_now then
          rx_count <= rx_count + 1;
        elsif rx_pop_now and not rx_push_accepted then
          rx_count <= rx_count - 1;
        end if;

      end if;
    end if;
  end process;

end rtl;
