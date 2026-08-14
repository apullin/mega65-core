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
    -- Where the 8 MB window sits in PS DDR.  Must match the reserved-memory
    -- node Linux is given (see tools/user-override.dtb and HANDOVER.md).
    --
    -- Deliberately NOT 0x70000000: U-Boot loads user-override.dtb to exactly
    -- that address, and marking it no-map is asking the kernel to treat the
    -- memory holding its own device tree as absent.
    BASE_ADDR : unsigned(31 downto 0) := x"78000000";
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

  ------------------------------------------------------------------------------
  -- CLOCK DOMAINS
  --
  -- The core drives this interface from pixelclock; the AXI side runs on the
  -- interconnect's clock.  The first version ran the state machine on the AXI
  -- clock and sampled the core's signals directly, which is simply wrong -- it
  -- produced 177 failing endpoints, all of them this crossing.
  --
  -- Now it is a request/ack toggle handshake, the same shape as
  -- dp_audio_axis: the core side latches the request and toggles req; the AXI
  -- side sees the toggle, runs the transaction against the *latched* values,
  -- and toggles ack.  Between those two events the latched address and data
  -- cannot move, so they are ordinary stable signals rather than a race.
  ------------------------------------------------------------------------------
  signal req_tog   : std_logic := '0';
  signal req_sync  : std_logic_vector(2 downto 0) := (others => '0');
  signal ack_tog   : std_logic := '0';
  signal ack_sync  : std_logic_vector(2 downto 0) := (others => '0');

  signal lat_addr  : unsigned(26 downto 0) := (others => '0');
  signal lat_wdata : unsigned(7 downto 0) := (others => '0');
  signal lat_write : std_logic := '0';
  signal lat_rdata : unsigned(7 downto 0) := (others => '0');

  type state_t is (IDLE, RD_ADDR, RD_DATA, WR_ADDR, WR_DATA, WR_RESP, DONE);
  signal state : state_t := IDLE;

  -- AXI-domain working registers.
  signal req_addr  : unsigned(31 downto 0) := (others => '0');
  signal byte_lane : integer range 0 to 3 := 0;
  signal wr_byte   : std_logic_vector(7 downto 0) := (others => '0');

  signal toggle_i  : std_logic := '0';
  -- Starts READY, not busy.  Starting busy deadlocks: the core-side process
  -- only accepts a request while not busy, and only clears busy on an ack --
  -- so with no first request there is never an ack, and busy stays high
  -- forever.  The symptom is every attic address reading back the same
  -- constant and writes doing nothing, because no transaction ever completes.
  -- Unlike a real DRAM there is nothing to initialise here: the FSBL brought
  -- the controller up long before the PL was loaded.
  signal busy_i    : std_logic := '0';


begin

  busy              <= busy_i;
  data_ready_toggle <= toggle_i;

  -- Core clock domain.
  process (clock)
  begin
    if rising_edge(clock) then
      ack_sync <= ack_sync(1 downto 0) & ack_tog;

      if busy_i = '0' then
        if read_request = '1' or write_request = '1' then
          lat_addr  <= address;
          lat_wdata <= wdata;
          lat_write <= write_request;
          req_tog   <= not req_tog;
          busy_i    <= '1';
        end if;
      elsif ack_sync(2) /= ack_sync(1) then
        -- transaction complete; the AXI side is no longer touching lat_rdata
        rdata    <= lat_rdata;
        toggle_i <= not toggle_i;
        busy_i   <= '0';
      end if;
    end if;
  end process;

  process (m_axi_aclk)
    variable a : unsigned(31 downto 0);
  begin
    if rising_edge(m_axi_aclk) then
      if m_axi_aresetn = '0' then
        state         <= IDLE;
        m_axi_awvalid <= '0';
        m_axi_wvalid  <= '0';
        m_axi_bready  <= '0';
        m_axi_arvalid <= '0';
        m_axi_rready  <= '0';
        req_sync      <= (others => '0');
      else
        req_sync <= req_sync(1 downto 0) & req_tog;

        case state is
          when IDLE =>
            -- wrap rather than run off the end, as the real machine does
            a := BASE_ADDR + resize(lat_addr(ADDR_BITS-1 downto 0), 32);
            byte_lane <= to_integer(a(1 downto 0));
            req_addr  <= a(31 downto 2) & "00";

            if req_sync(2) /= req_sync(1) then
              if lat_write = '1' then
                wr_byte       <= std_logic_vector(lat_wdata);
                m_axi_awaddr  <= std_logic_vector(a(31 downto 2) & "00");
                m_axi_awvalid <= '1';
                state         <= WR_ADDR;
              else
                m_axi_araddr  <= std_logic_vector(a(31 downto 2) & "00");
                m_axi_arvalid <= '1';
                state         <= RD_ADDR;
              end if;
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
                when 0 => lat_rdata <= unsigned(m_axi_rdata(7 downto 0));
                when 1 => lat_rdata <= unsigned(m_axi_rdata(15 downto 8));
                when 2 => lat_rdata <= unsigned(m_axi_rdata(23 downto 16));
                when 3 => lat_rdata <= unsigned(m_axi_rdata(31 downto 24));
              end case;
              state <= DONE;
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
            -- tell the core we are finished; it owns lat_rdata from here
            ack_tog <= not ack_tog;
            state   <= IDLE;
        end case;
      end if;
    end if;
  end process;

end rtl;
