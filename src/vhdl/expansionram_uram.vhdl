--------------------------------------------------------------------------------
-- UltraRAM-backed expansion ("attic") RAM for UltraScale+ targets.
--
-- Drop-in replacement for the HyperRAM controller as far as slow_devices is
-- concerned: same request/response interface, no external memory chip.
--
-- WHY THIS AND NOT chip RAM
--
-- UltraRAM is a poor fit for the MEGA65's chip RAM (see PORTING-NOTES §20): that
-- is cycle-exact, dual-clock (CPU 40.5 MHz / VIC-IV 81 MHz) and read
-- combinationally, and no URAM scheme fits in the available slack. The attic RAM
-- has none of those properties -- it is explicitly slow, banked, and handshaked
-- -- so URAM suits it exactly. It also costs nothing that was working before,
-- because this target previously had no expansion RAM at all
-- (hyper_installed => false).
--
-- PACKING
--
-- URAM288 is 4096 deep x 72 bits. Addressing it a byte at a time would waste
-- 8 bits in 72 and need 8x the blocks, so bytes are packed 8 per 64-bit word
-- (64 of 72 bits used, 11% waste, power-of-two addressing kept):
--
--     word = address(ADDR_BITS-1 downto 3)
--     byte = address(2 downto 0)
--
-- URAM288 has per-byte write enables, so byte writes are native -- no
-- read-modify-write. This is the detail that makes the whole approach work.
--
-- Inference via ram_style="ultra" does NOT work here (Vivado rejects it with
-- "invalid write mode" and silently falls back to BRAM), so the XPM macro is
-- used directly.
--
-- SIZE
--
-- ADDR_BITS = 21 gives 2 MB, which is 64 URAM blocks -- the whole device.
-- ADDR_BITS = 20 gives 1 MB / 32 blocks, leaving half the URAM for other uses.
--
-- Note this is smaller than the 8 MB of attic RAM on real MEGA65 hardware.
-- Addresses above the implemented size ALIAS (wrap), they do not fault. Software
-- that assumes 8 MB will see aliasing rather than an error.
--
-- CLOCKING
--
-- Clocked from pixelclock, because that is the clock slow_devices' expansion RAM
-- state machine runs on. Single clock, which is all URAM supports.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity expansionram_uram is
  generic (
    -- Byte-address width. 21 = 2 MB (64 URAM), 20 = 1 MB (32 URAM).
    ADDR_BITS : integer := 21
  );
  port (
    clock : in std_logic;                       -- pixelclock

    address       : in  unsigned(26 downto 0);
    wdata         : in  unsigned(7 downto 0);
    read_request  : in  std_logic;
    write_request : in  std_logic;

    rdata             : out unsigned(7 downto 0) := x"00";
    data_ready_toggle : out std_logic := '0';
    busy              : out std_logic := '1'
  );
end expansionram_uram;

architecture rtl of expansionram_uram is

  constant WORD_ADDR_BITS : integer := ADDR_BITS - 3;

  signal mem_addr : std_logic_vector(WORD_ADDR_BITS-1 downto 0) := (others => '0');
  signal mem_din  : std_logic_vector(63 downto 0) := (others => '0');
  signal mem_dout : std_logic_vector(63 downto 0);
  signal mem_we   : std_logic_vector(7 downto 0) := (others => '0');
  signal mem_en   : std_logic := '0';

  signal byte_sel : unsigned(2 downto 0) := (others => '0');

  type state_t is (IDLE, WR_DONE, RD1, RD2, RD3);
  signal state : state_t := IDLE;

  signal toggle_i : std_logic := '0';

begin

  data_ready_toggle <= toggle_i;

  -- The write byte is replicated across all eight lanes; the byte enable picks
  -- which one actually lands.
  mem_din <= std_logic_vector(wdata) & std_logic_vector(wdata)
           & std_logic_vector(wdata) & std_logic_vector(wdata)
           & std_logic_vector(wdata) & std_logic_vector(wdata)
           & std_logic_vector(wdata) & std_logic_vector(wdata);

  process (clock)
  begin
    if rising_edge(clock) then

      -- Defaults: no access this cycle
      mem_en <= '0';
      mem_we <= (others => '0');

      case state is

        when IDLE =>
          busy <= '0';
          mem_addr <= std_logic_vector(address(ADDR_BITS-1 downto 3));
          byte_sel <= address(2 downto 0);

          if write_request = '1' then
            -- Fire and forget: slow_devices acknowledges writes immediately and
            -- does not wait for us.
            mem_en <= '1';
            mem_we <= (others => '0');
            mem_we(to_integer(address(2 downto 0))) <= '1';
            busy  <= '1';
            state <= WR_DONE;

          elsif read_request = '1' then
            mem_en <= '1';
            busy   <= '1';
            state  <= RD1;
          end if;

        when WR_DONE =>
          -- One cycle for the write to retire before accepting anything else.
          busy  <= '0';
          state <= IDLE;

        -- READ_LATENCY_A = 2, so mem_dout is valid two clocks after the cycle
        -- in which mem_en was asserted. One extra cycle of margin costs nothing
        -- on a memory the CPU already treats as slow.
        when RD1 =>
          state <= RD2;

        when RD2 =>
          state <= RD3;

        when RD3 =>
          rdata <= unsigned(mem_dout((to_integer(byte_sel)+1)*8-1
                                     downto to_integer(byte_sel)*8));
          -- slow_devices waits for this to CHANGE, not for a level.
          toggle_i <= not toggle_i;
          busy     <= '0';
          state    <= IDLE;

      end case;
    end if;
  end process;

  mem : xpm_memory_spram
    generic map (
      MEMORY_SIZE        => (2**WORD_ADDR_BITS) * 64,
      MEMORY_PRIMITIVE   => "ultra",
      MEMORY_INIT_FILE   => "none",
      USE_MEM_INIT       => 0,
      WAKEUP_TIME        => "disable_sleep",
      AUTO_SLEEP_TIME    => 0,
      MESSAGE_CONTROL    => 0,
      ECC_MODE           => "no_ecc",

      WRITE_DATA_WIDTH_A => 64,
      READ_DATA_WIDTH_A  => 64,
      BYTE_WRITE_WIDTH_A => 8,
      ADDR_WIDTH_A       => WORD_ADDR_BITS,
      READ_RESET_VALUE_A => "0",
      READ_LATENCY_A     => 2,
      WRITE_MODE_A       => "no_change"
    )
    port map (
      clka           => clock,
      rsta           => '0',
      ena            => mem_en,
      wea            => mem_we,
      addra          => mem_addr,
      dina           => mem_din,
      douta          => mem_dout,
      regcea         => '1',
      injectsbiterra => '0',
      injectdbiterra => '0',
      sleep          => '0',
      sbiterra       => open,
      dbiterra       => open
    );

end rtl;
