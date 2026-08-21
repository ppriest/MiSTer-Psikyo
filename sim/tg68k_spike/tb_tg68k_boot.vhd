-------------------------------------------------------------------------------
-- Phase 0 spike testbench, v3: boot TG68K.C in 68020 mode out of reset and
-- run a program exercising actual 68020-only additions over base 68000:
-- 32x32->32 MULU.L, 32/32->32 DIVU.L, 68020-only scaled-index addressing
-- ((d8,An,Xn.L*4)), and a BFEXTU bitfield extract. None of these exist on
-- plain 68000/68010, so this is the real test of "does 68020 mode work",
-- as opposed to v1/v2 which only exercised the classic async bus wrapper
-- with base-68000-compatible opcodes.
--
-- The program is in sim/tg68k_spike/test020.s, assembled with a
-- self-built vasm (vasmm68k_mot -m68020 -Fbin; see PROVENANCE.md for why:
-- v1/v2 hand-encoded opcodes directly and got bitten twice by transcription
-- mistakes that looked exactly like core bugs at first). The resulting
-- binary is converted straight into the mem_v ROM initialization below by
-- gen_rom_vhdl.py -- there is no hand-transcribed machine code in this
-- file anymore.
--
-- Each result is written to a distinct, recognizable address so the bus
-- trace can confirm it directly:
--   0x3000/0x3002 <= MULU.L result   = 0x000222E0  (70000 * 2 = 140000)
--   0x3004/0x3006 <= DIVU.L result   = 0x000037CD  (100000 / 7 = 14285)
--   0x3008/0x300A <= scaled-index EA = 0xCCCCCCCC  (table[2])
--   0x300C/0x300E <= BFEXTU result   = 0x00000034  (byte 1 of 0x12345678)
--
-- Pass condition (this testbench's automated check): the final write pair
-- (0x0000/0x0034 to 0x300C/0x300E) is observed. The other three results
-- are verified by inspecting the bus trace after the run, not by
-- additional VHDL monitor logic (deliberately -- less new VHDL here means
-- less chance of yet another self-inflicted testbench bug).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

entity tb_tg68k_boot is
end entity;

architecture sim of tb_tg68k_boot is

   component TG68K is
      generic(
         CPU : std_logic_vector(1 downto 0) := "01"
      );
      port(
         CLK    : in std_logic;
         RESET  : inout std_logic;
         HALT   : inout std_logic;
         BERR   : in std_logic;
         IPL    : in std_logic_vector(2 downto 0) := "111";
         ADDR   : out std_logic_vector(31 downto 0);
         FC     : out std_logic_vector(2 downto 0);
         DATA   : inout std_logic_vector(15 downto 0);
         AS     : out std_logic;
         UDS    : out std_logic;
         LDS    : out std_logic;
         RW     : out std_logic;
         DTACK  : in std_logic;
         E      : out std_logic;
         VPA    : in std_logic;
         VMA    : out std_logic
      );
   end component;

   signal clk      : std_logic := '0';
   signal reset_n  : std_logic := '0';
   signal halt_n   : std_logic := '0';
   signal berr     : std_logic := '0';
   signal ipl      : std_logic_vector(2 downto 0) := "111";
   signal addr     : std_logic_vector(31 downto 0);
   signal fc       : std_logic_vector(2 downto 0);
   signal data     : std_logic_vector(15 downto 0);
   signal as_n     : std_logic;
   signal uds_n    : std_logic;
   signal lds_n    : std_logic;
   signal rw       : std_logic;
   signal dtack_n  : std_logic := '1';
   signal e_clk    : std_logic;
   signal vpa      : std_logic := '1';
   signal vma      : std_logic;

   -- 64K-word (128KB) memory model, word-addressed on ADDR(16 downto 1)
   type mem_t is array (0 to 65535) of std_logic_vector(15 downto 0);

   signal sim_done   : boolean := false;
   signal write_seen : boolean := false;

   function widx(a : std_logic_vector(31 downto 0)) return integer is
   begin
      return conv_integer(a(16 downto 1));
   end function;

begin

   dut: TG68K
      generic map (CPU => "11")   -- 68020
      port map (
         CLK   => clk,
         RESET => reset_n,
         HALT  => halt_n,
         BERR  => berr,
         IPL   => ipl,
         ADDR  => addr,
         FC    => fc,
         DATA  => data,
         AS    => as_n,
         UDS   => uds_n,
         LDS   => lds_n,
         RW    => rw,
         DTACK => dtack_n,
         E     => e_clk,
         VPA   => vpa,
         VMA   => vma
      );

   -- 50MHz-equivalent free-running clock (period value is arbitrary for sim)
   clk_gen: process
   begin
      while not sim_done loop
         clk <= '0'; wait for 10 ns;
         clk <= '1'; wait for 10 ns;
      end loop;
      wait;
   end process;

   -- Power-on reset pulse, then release to weak-high so the DUT's own
   -- (inout, 'Z'-when-inactive) reset driver is free to assert it later.
   --
   -- NOTE: TG68K.vhd derives the kernel's active-low nReset as
   -- "cpu1reset <= RESET OR HALT" -- both top-level RESET and HALT must be
   -- driven low simultaneously to actually assert reset. Driving only
   -- RESET (leaving HALT released) resolves to nReset='1' (i.e. NOT reset)
   -- and was the cause of this spike's first failed run: the kernel never
   -- initialized and produced 'X' internal state from cycle 1.
   reset_gen: process
   begin
      reset_n <= '0';
      halt_n  <= '0';
      wait for 200 ns;
      reset_n <= 'H';
      halt_n  <= 'H';
      wait;
   end process;

   -- Zero-wait-state DTACK: assert as soon as the bus cycle starts.
   dtack_n <= '0' when as_n = '0' else '1';

   -- Memory model: single process owning the storage as a process-local
   -- variable (not a signal) so there's exactly one driver for `data` and
   -- no multi-driver resolution hazard on the storage itself. Reads are
   -- combinational (re-evaluated whenever the bus changes); writes are
   -- captured synchronously, gated per byte lane by UDS/LDS. Preloaded
   -- with the reset vectors + test program described in the header.
   memory: process(clk, as_n, rw, addr, uds_n, lds_n)
      variable mem_v : mem_t := (others => x"0000");
      variable init_done : boolean := false;
   begin
      if not init_done then
         -- Generated by gen_rom_vhdl.py from test020.bin (vasm -m68020
         -- output) -- do not hand-edit, regenerate instead. See
         -- test020.s / test020.lst for the source and disassembly.
         mem_v(0   ) := x"0000";  -- byte addr 0x0000
         mem_v(1   ) := x"8000";  -- byte addr 0x0002
         mem_v(2   ) := x"0000";  -- byte addr 0x0004
         mem_v(3   ) := x"0008";  -- byte addr 0x0006
         mem_v(4   ) := x"203C";  -- byte addr 0x0008
         mem_v(5   ) := x"0001";  -- byte addr 0x000A
         mem_v(6   ) := x"1170";  -- byte addr 0x000C
         mem_v(7   ) := x"7202";  -- byte addr 0x000E
         mem_v(8   ) := x"4C01";  -- byte addr 0x0010
         mem_v(9   ) := x"0000";  -- byte addr 0x0012
         mem_v(10  ) := x"23C0";  -- byte addr 0x0014
         mem_v(11  ) := x"0000";  -- byte addr 0x0016
         mem_v(12  ) := x"3000";  -- byte addr 0x0018
         mem_v(13  ) := x"243C";  -- byte addr 0x001A
         mem_v(14  ) := x"0001";  -- byte addr 0x001C
         mem_v(15  ) := x"86A0";  -- byte addr 0x001E
         mem_v(16  ) := x"7607";  -- byte addr 0x0020
         mem_v(17  ) := x"4C43";  -- byte addr 0x0022
         mem_v(18  ) := x"2002";  -- byte addr 0x0024
         mem_v(19  ) := x"23C2";  -- byte addr 0x0026
         mem_v(20  ) := x"0000";  -- byte addr 0x0028
         mem_v(21  ) := x"3004";  -- byte addr 0x002A
         mem_v(22  ) := x"41F8";  -- byte addr 0x002C
         mem_v(23  ) := x"004E";  -- byte addr 0x002E
         mem_v(24  ) := x"7202";  -- byte addr 0x0030
         mem_v(25  ) := x"2830";  -- byte addr 0x0032
         mem_v(26  ) := x"1C00";  -- byte addr 0x0034
         mem_v(27  ) := x"23C4";  -- byte addr 0x0036
         mem_v(28  ) := x"0000";  -- byte addr 0x0038
         mem_v(29  ) := x"3008";  -- byte addr 0x003A
         mem_v(30  ) := x"203C";  -- byte addr 0x003C
         mem_v(31  ) := x"1234";  -- byte addr 0x003E
         mem_v(32  ) := x"5678";  -- byte addr 0x0040
         mem_v(33  ) := x"E9C0";  -- byte addr 0x0042
         mem_v(34  ) := x"5208";  -- byte addr 0x0044
         mem_v(35  ) := x"23C5";  -- byte addr 0x0046
         mem_v(36  ) := x"0000";  -- byte addr 0x0048
         mem_v(37  ) := x"300C";  -- byte addr 0x004A
         mem_v(38  ) := x"60FE";  -- byte addr 0x004C
         mem_v(39  ) := x"AAAA";  -- byte addr 0x004E
         mem_v(40  ) := x"AAAA";  -- byte addr 0x0050
         mem_v(41  ) := x"BBBB";  -- byte addr 0x0052
         mem_v(42  ) := x"BBBB";  -- byte addr 0x0054
         mem_v(43  ) := x"CCCC";  -- byte addr 0x0056
         mem_v(44  ) := x"CCCC";  -- byte addr 0x0058
         mem_v(45  ) := x"DDDD";  -- byte addr 0x005A
         mem_v(46  ) := x"DDDD";  -- byte addr 0x005C
         init_done := true;
      end if;

      -- combinational read
      if as_n = '0' and rw = '1' then
         data <= mem_v(widx(addr));
      else
         data <= (others => 'Z');
      end if;

      -- synchronous write
      if rising_edge(clk) then
         if as_n = '0' and rw = '0' then
            if uds_n = '0' then
               mem_v(widx(addr))(15 downto 8) := data(15 downto 8);
            end if;
            if lds_n = '0' then
               mem_v(widx(addr))(7 downto 0) := data(7 downto 0);
            end if;
         end if;
      end if;
   end process;

   -- Pass/fail monitor: watch for the LAST expected write pair (BFEXTU
   -- result 0x00000034 to 0x300C/0x300E), the final thing the program
   -- does before looping. Reaching it means all four preceding
   -- instructions (MULU.L, DIVU.L, scaled-index MOVE.L, BFEXTU) executed
   -- without the CPU wedging/erroring; the bus_trace log is what actually
   -- confirms each intermediate result is *correct*, not just "reached".
   -- Uses the same settle-then-sample technique as bus_trace (see its
   -- comment) rather than bare rising_edge(clk) sensitivity, to avoid
   -- catching signals mid-delta-cycle-transition.
   monitor: process
      variable seen_hi : boolean := false;
   begin
      wait until rising_edge(clk);
      wait for 1 ns;
      if as_n = '0' and rw = '0' and uds_n = '0' and lds_n = '0' then
         if addr = x"0000300C" and data = x"0000" then
            seen_hi := true;
         elsif addr = x"0000300E" and data = x"0034" and seen_hi then
            write_seen <= true;
         end if;
      end if;
   end process;

   -- Diagnostic bus trace v2: unconditional per-tick waveform dump (not
   -- edge-detected -- v1's edge detector relied on as_n cleanly reaching
   -- '0' at some point, and produced ZERO output under `postponed`, which
   -- itself is evidence as_n may never settle to a clean known value at
   -- all). Sample shortly after each rising edge, once all deltas for that
   -- edge have settled, using an explicit small delay rather than
   -- `postponed` (which behaved unexpectedly here) or bare sensitivity
   -- (which races other same-edge processes).
   bus_trace: process
      variable n : integer := 0;
   begin
      wait until rising_edge(clk);
      wait for 1 ns;
      if n < 400 then
         report "tick " & integer'image(n) &
                "  addr=" & to_hstring(addr) &
                "  data=" & to_hstring(data) &
                "  as="   & std_logic'image(as_n) &
                "  rw="   & std_logic'image(rw) &
                "  uds="  & std_logic'image(uds_n) &
                "  lds="  & std_logic'image(lds_n) &
                "  dtack="& std_logic'image(dtack_n)
                severity note;
      end if;
      n := n + 1;
   end process;

   -- Single process (single driver for sim_done/write_seen consumption):
   -- wait for the write to complete, or time out.
   finish: process
   begin
      wait until write_seen for 200 us;
      if write_seen then
         report "REACHED END: BFEXTU result write observed -- check the tick log above for MULU.L/DIVU.L/scaled-index/BFEXTU result correctness at 0x3000/0x3004/0x3008/0x300C" severity note;
      else
         report "FAIL: timed out before reaching the BFEXTU result write at 0x300C -- program stalled or crashed partway through" severity failure;
      end if;
      sim_done <= true;
      wait;
   end process;

end architecture;
