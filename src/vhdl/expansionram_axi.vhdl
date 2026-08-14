--------------------------------------------------------------------------------
-- Attic RAM backed by the PS DDR, over AXI.
--
-- WHY THIS REPLACES THE URAM VERSION
--
-- expansionram_uram.vhdl puts the attic RAM in UltraRAM, which is fast and
-- entirely in the fabric -- but the XCK26 only has 64 URAM blocks, 2 MB, and
-- the MEGA65 expects 8 MB.  The URAM version therefore aliases: four different
-- addresses land on the same byte.  Software that assumes 8 MB corrupts itself
-- quietly, which is worse than not having the RAM at all.
--
-- The K26 SOM has no PL-attached DRAM; the 4 GB DDR4 belongs to the PS.  So
-- 8 MB of real attic RAM means reaching into PS DDR, which is what this does.
--
-- This does not make the machine depend on Linux.  The FSBL brings the DDR
-- controller up at boot, and after that the PL masters into DDR through an
-- AXI port with no software involved at all -- it is PS *hardware*, in the
-- same sense that the DisplayPort block is.  Nothing here needs a driver, a
-- daemon, or an operating system.
--
-- THE MEMORY MUST BE RESERVED
--
-- Linux has to be told not to use this region, or it will hand the same pages
-- to userspace and the two will fight.  Reserve it with a reserved-memory node
-- or a `mem=` boot argument covering BASE_ADDR .. BASE_ADDR + 8 MB.  Get this
-- wrong and the symptom is random corruption in both directions, which is
-- miserable to debug -- so the default base sits high, well clear of where the
-- kernel loads.
--
-- PERFORMANCE
--
-- One AXI transaction per byte, which is not fast: a DDR round trip through
-- the PS interconnect is on the order of 100-200 ns, so roughly 5-10 MB/s.
-- That is deliberate for a first version -- correctness before speed -- and it
-- is in the same ballpark as the HyperRAM the attic RAM normally lives in, so
-- software written for a real MEGA65 will not be surprised.  The obvious
-- improvement is a small line buffer: read 8 or 16 bytes per transaction and
-- serve sequential accesses from it, which is how most attic RAM traffic
-- behaves.  Left for later, because a wrong cache is worse than a slow bus.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity expansionram_axi is
  generic (
    -- Where the 8 MB window sits in PS DDR.  Must match whatever Linux is told
    -- to keep its hands off.
    BASE_ADDR : unsigned(31 downto 0) := x"70000000";
    -- 8 MB of attic RAM; addresses above this wrap, as on real hardware.
    ADDR_BITS : integer := 23
  );
  port (
    clock : in std_logic;

    -- the core's expansion RAM interface, unchanged from the URAM version
    address       : in  unsigned(26 downto 0);
    wdata         : in  unsigned(7 downto 0);
    read_request  : in  std_logic;
    write_request : in  std_logic;
    rdata             : out unsigned(7 downto 0) := x"00";
    data_ready_toggle : out std_logic := '0';
    busy              : out std_logic := '1';

    -- AXI4-Lite master, to a PS high-performance slave port
    m_axi_aclk    : in  std_logic;
    m_axi_aresetn : in  std_logic;

    m_axi_awaddr  : out std_logic_vector(31 downto 0) := (others => '0');
    m_axi_awprot  : out std_logic_vector(2 downto 0)  := "000";
    m_axi_awvalid : out std_logic := '0';
    m_axi_awready : in  std_logic;
    m_axi_wdata   : out std_logic_vector(31 downto 0) := (others => '0');
    m_axi_wstrb   : out std_logic_vector(3 downto 0)  := "0000";
    m_axi_wvalid  : out std_logic := '0';
    m_axi_wready  : in  std_logic;
    m_axi_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_bvalid  : in  std_logic;
    m_axi_bready  : out std_logic := '0';

    m_axi_araddr  : out std_logic_vector(31 downto 0) := (others => '0');
    m_axi_arprot  : out std_logic_vector(2 downto 0)  := "000";
    m_axi_arvalid : out std_logic := '0';
    m_axi_arready : in  std_logic;
    m_axi_rdata   : in  std_logic_vector(31 downto 0);
    m_axi_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_rvalid  : in  std_logic;
    m_axi_rready  : out std_logic := '0'
  );
end expansionram_axi;

architecture rtl of expansionram_axi is

  type state_t is (IDLE, RD_ADDR, RD_DATA, WR_ADDR, WR_DATA, WR_RESP, DONE);
  signal state : state_t := IDLE;

  -- The core's clock and the AXI clock are the same net in this design (both
  -- pl_clk0-derived), so no crossing is needed here.  Kept as separate ports
  -- anyway, so a future build can put the AXI side on a faster clock without
  -- rewriting the interface.
  signal req_addr  : unsigned(31 downto 0) := (others => '0');
  signal byte_lane : integer range 0 to 3 := 0;
  signal wr_byte   : std_logic_vector(7 downto 0) := (others => '0');

  signal toggle_i  : std_logic := '0';
  signal busy_i    : std_logic := '1';

  -- Requests are edge-triggered: the core raises read_request/write_request
  -- and we must not re-run the same transaction while it is still high.
  signal rd_last : std_logic := '0';
  signal wr_last : std_logic := '0';

begin

  busy              <= busy_i;
  data_ready_toggle <= toggle_i;

  process (m_axi_aclk)
    variable a : unsigned(31 downto 0);
  begin
    if rising_edge(m_axi_aclk) then
      if m_axi_aresetn = '0' then
        state         <= IDLE;
        busy_i        <= '1';
        m_axi_awvalid <= '0';
        m_axi_wvalid  <= '0';
        m_axi_bready  <= '0';
        m_axi_arvalid <= '0';
        m_axi_rready  <= '0';
        rd_last       <= '0';
        wr_last       <= '0';
      else
        rd_last <= read_request;
        wr_last <= write_request;

        case state is
          when IDLE =>
            busy_i <= '0';
            -- wrap rather than run off the end, as the real machine does
            a := BASE_ADDR + resize(address(ADDR_BITS-1 downto 0), 32);
            byte_lane <= to_integer(a(1 downto 0));
            req_addr  <= a(31 downto 2) & "00";

            if read_request = '1' and rd_last = '0' then
              busy_i        <= '1';
              m_axi_araddr  <= std_logic_vector(a(31 downto 2) & "00");
              m_axi_arvalid <= '1';
              state         <= RD_ADDR;
            elsif write_request = '1' and wr_last = '0' then
              busy_i        <= '1';
              wr_byte       <= std_logic_vector(wdata);
              m_axi_awaddr  <= std_logic_vector(a(31 downto 2) & "00");
              m_axi_awvalid <= '1';
              state         <= WR_ADDR;
            end if;

          when RD_ADDR =>
            if m_axi_arready = '1' then
              m_axi_arvalid <= '0';
              m_axi_rready  <= '1';
              state         <= RD_DATA;
            end if;

          when RD_DATA =>
            if m_axi_rvalid = '1' then
              m_axi_rready <= '0';
              case byte_lane is
                when 0 => rdata <= unsigned(m_axi_rdata(7 downto 0));
                when 1 => rdata <= unsigned(m_axi_rdata(15 downto 8));
                when 2 => rdata <= unsigned(m_axi_rdata(23 downto 16));
                when 3 => rdata <= unsigned(m_axi_rdata(31 downto 24));
              end case;
              -- the core watches for this to change, not for a level
              toggle_i <= not toggle_i;
              state    <= DONE;
            end if;

          when WR_ADDR =>
            if m_axi_awready = '1' then
              m_axi_awvalid <= '0';
            end if;
            -- write data can be presented independently of the address
            m_axi_wdata <= wr_byte & wr_byte & wr_byte & wr_byte;
            case byte_lane is
              when 0 => m_axi_wstrb <= "0001";
              when 1 => m_axi_wstrb <= "0010";
              when 2 => m_axi_wstrb <= "0100";
              when 3 => m_axi_wstrb <= "1000";
            end case;
            m_axi_wvalid <= '1';
            state        <= WR_DATA;

          when WR_DATA =>
            if m_axi_awready = '1' then
              m_axi_awvalid <= '0';
            end if;
            if m_axi_wready = '1' then
              m_axi_wvalid <= '0';
              m_axi_bready <= '1';
              state        <= WR_RESP;
            end if;

          when WR_RESP =>
            if m_axi_bvalid = '1' then
              m_axi_bready <= '0';
              state        <= DONE;
            end if;

          when DONE =>
            -- hold until the core drops its request, so one request is one
            -- transaction however long the core keeps the line high
            if read_request = '0' and write_request = '0' then
              busy_i <= '0';
              state  <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

end rtl;
