-------------------------------------------------------------------------------
-- Pure-VHDL counterpart to tb_tg68k_isolate.sv, built to directly test
-- whether ModelSim's mixed-language SV-instantiates-VHDL boundary is the
-- cause of a SIGSEGV+memory-exhaustion crash the SV version hit within the
-- first ~2 clock cycles of simulation, even reduced to the sharpest
-- possible isolation (spike's own trivial zero-wait DTACK, no address
-- decode, no RAM regions -- see rtl/cpu/maincpu.sv's header for the full
-- fix history this is checking).
--
-- Deliberately as close to sim/tg68k_spike/tb_tg68k_boot.vhd as possible
-- (same component declaration, same reset_n/halt_n '0'-then-weak-'H'
-- pattern for BOTH lines together, same zero-wait DTACK, same NOP-forever
-- ROM), with exactly one real difference: VPA is gated to only assert
-- during an actual interrupt-acknowledge cycle (FC="111"), matching
-- maincpu.sv's fix, instead of the spike's own constant '1' (inactive) --
-- the spike never tested interrupts at all, so this checks whether that
-- specific fix is itself sound in pure VHDL, not just "did the spike's
-- exact code still work" (which would prove nothing new).
--
-- If this crashes too: the bug is in the VPA-gating logic itself (or
-- something else genuinely RTL-level), independent of language. If this
-- runs clean: the crash is specific to the mixed-language SV/VHDL
-- boundary for this core, not to any of the reset/HALT/VPA fixes
-- themselves.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

entity tb_tg68k_isolate is
end entity;

architecture sim of tb_tg68k_isolate is

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
   signal dtack_n  : std_logic;
   signal e_clk    : std_logic;
   signal vpa      : std_logic;
   signal vma      : std_logic;

   signal sim_done : boolean := false;

begin

   dut: TG68K
      generic map (CPU => "11")
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

   clk_gen: process
   begin
      while not sim_done loop
         clk <= '0'; wait for 5 ns;
         clk <= '1'; wait for 5 ns;
      end loop;
      wait;
   end process;

   -- Both RESET and HALT together, '0' then weak-'H' -- see
   -- sim/tg68k_spike/tb_tg68k_boot.vhd's own note on why both are needed.
   reset_gen: process
   begin
      reset_n <= '0';
      halt_n  <= '0';
      wait for 200 ns;
      reset_n <= 'H';
      halt_n  <= 'H';
      wait;
   end process;

   -- VPA gated to interrupt-acknowledge cycles only (fc="111"), NOT the
   -- spike's own constant '1' -- this is the one real difference from
   -- tb_tg68k_boot.vhd, specifically to test maincpu.sv's VPA fix in pure
   -- VHDL.
   vpa <= '0' when fc = "111" else '1';

   -- Zero-wait DTACK, identical to the spike.
   dtack_n <= '0' when as_n = '0' else '1';

   -- BRA.S to self (opcode 0x60FE, displacement -2 -> targets its own
   -- address) instead of NOP-forever: distinguishes whether the eventual
   -- crash tracks raw cycle count (would still happen here, same as NOP)
   -- or address progression (NOP continuously increments PC/the address
   -- bus every fetch; this tight self-branch re-fetches the exact same
   -- address forever and never advances PC at all).
   data <= x"60FE" when (as_n = '0' and rw = '1') else (others => 'Z');

   monitor: process
      variable n : integer := 0;
   begin
      wait until rising_edge(clk);
      wait for 1 ns;
      if n < 40000 then
         n := n + 1;
      else
         sim_done <= true;
         report "Ran 40000 cycles with no crash -- pure-VHDL isolation is clean, mixed-language SV/VHDL boundary is the likely cause" severity note;
         wait;
      end if;
   end process;

end architecture;
