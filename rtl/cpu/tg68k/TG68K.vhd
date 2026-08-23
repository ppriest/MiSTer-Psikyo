------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- This is the TOP-Level for TG68K.C to generate 68K Bus signals            --
--                                                                          --
-- Copyright (c) 2021 Tobias Gubener <tobiflex@opencores.org>               -- 
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity TG68K is
   generic(
      CPU           : std_logic_vector(1 downto 0):="01"  -- 00->68000  01->68010  11->68020
   );
   port(        
      CLK           : in std_logic;
      RESET         : inout std_logic;
      HALT          : inout std_logic;
      BERR          : in std_logic;     -- only 68000 Stackpointer dummy for Atari ST core
      IPL           : in std_logic_vector(2 downto 0):="111";
      ADDR          : out std_logic_vector(31 downto 0);
      FC            : out std_logic_vector(2 downto 0);
      DATA          : inout std_logic_vector(15 downto 0);
---- bus controll      
--      BG            : out std_logic;
--      BR         	  : in std_logic:='1';
--      BGACK         : in std_logic:='1';
-- async interface      
      AS            : out std_logic;
      UDS           : out std_logic;
      LDS           : out std_logic;
      RW            : out std_logic;
      DTACK         : in std_logic;
-- sync interface
      E             : out std_logic;
      VPA           : in std_logic;
      VMA           : out std_logic;

      -- Real-hardware fix (docs/ROADMAP.md, CONFIRMED on real hardware --
      -- the CPU now generates real bus cycles). RESET/HALT are genuine
      -- open-collector nets (this architecture's own driver below, PLUS
      -- maincpu.sv's external one) needing tri-state resolution to reach
      -- their idle-high default once both sides release. A real
      -- quartus_fit run showed Quartus synthesizing that resolution as a
      -- plain selector (Warning (13048)) rather than genuine wired-AND,
      -- and a live hardware bisection (a temporary debug tap driving a
      -- real screen color -- see git history if the technique is needed
      -- again) confirmed the idle-high default never actually resolves --
      -- cpu1reset read stuck low permanently, holding the CPU in reset
      -- forever. Two attempts to fix this by making RESET/HALT's own
      -- drivers non-tri-state hit real Quartus synthesis errors (13076,
      -- "multiple drivers") on cpu1reset itself, then on the kernel's own
      -- internal syncReset register -- this architecture's own driver on
      -- RESET/HALT (below) means any non-tri-state alternative on the
      -- same net is a genuine conflict, not just an ambiguity Quartus can
      -- optimize around. Fixed instead with an entirely separate,
      -- single-driver, non-tri-state signal ORed into cpu1reset's own
      -- computation (below) -- doesn't touch RESET/HALT at all, so it
      -- can't create a multi-driver conflict with this architecture's own
      -- driver on those nets. Drive '1' whenever the caller wants normal
      -- (not-reset) operation; has no effect during active reset (RESET/
      -- HALT's own strong-0-vs-Z resolution during that window was never
      -- the broken case -- only the idle/steady-state release was).
      ext_force_run : in std_logic := '0';

      -- Real-hardware fix, part 3 (docs/LESSONS_LEARNED.md). This
      -- architecture was written to be clocked AT the target CPU speed --
      -- it has no clock-enable input of its own, and the kernel's clkena
      -- below is derived purely from bus state, so with CLK tied to a fast
      -- system clock the whole CPU free-runs at that speed. Psikyo's real
      -- 68EC020 is 16 MHz (MAME psikyo.cpp sngkace(), "verified on pcb")
      -- while this project's clk_sys is 85.909091 MHz, so the CPU ran 5.4x
      -- too fast AND, fatally, far above what TG68K.C can physically close:
      -- quartus_sta measured TG68KdotC_Kernel's Fmax at 48.74 MHz on the
      -- real post-fit netlist. Drive ext_clkena with a one-CLK-wide pulse
      -- at the desired CPU rate to step the core at that rate instead.
      --
      -- It gates EVERY clocked process in this architecture, not just the
      -- kernel, so one pulse == exactly one emulated CPU clock cycle with
      -- all internal rising/falling-edge relationships preserved. Gating
      -- only the kernel would be actively wrong: the bus state machine
      -- generates clkena_e as a one-CLK pulse, and an ungated bus machine
      -- would routinely pulse it on a cycle the gated kernel is asleep for,
      -- losing bus-cycle completions outright.
      --
      -- Callers must present DTACK as a HELD LEVEL, not a one-cycle pulse:
      -- DTACK is now sampled once per CPU cycle rather than every CLK.
      -- Defaults to '1' so existing full-rate instantiations are unchanged.
      ext_clkena    : in std_logic := '1';

      -- Companion enable for this architecture's FALLING-edge processes,
      -- and NOT optional when ext_clkena is used: drive it with ext_clkena
      -- delayed by exactly one CLK period.
      --
      -- One enable cannot serve both edges. A rising-edge register samples
      -- the enable held during the PRECEDING period, so if ext_clkena is
      -- high throughout period P the rising-edge work fires at the END of
      -- P -- while the falling edge INSIDE P occurs half a period BEFORE
      -- that. Gating both edges with the same signal therefore runs each
      -- emulated CPU cycle's two halves in the wrong order.
      --
      -- Caught by sim/maincpu_tb/tb_maincpu.sv's sound-latch check: the CPU
      -- reached S_state="01" with the correct data in data_write (0x7777),
      -- but data_akt_e/data_akt_s were still '0', so DATA sat at 'Z' and
      -- the write captured high-impedance instead of the byte. The same
      -- misordering also skews AS/UDS/LDS/RW assertion and the falling-edge
      -- DTACK sample (waitm), so it is not a cosmetic ordering nit.
      ext_clkena_f  : in std_logic := '1'
   );
end TG68K;

ARCHITECTURE logic OF TG68K IS


COMPONENT TG68KdotC_Kernel 
   generic(
      SR_Read : integer:= 2;           --0=>user,     1=>privileged,    2=>switchable with CPU(0)
      VBR_Stackframe : integer:= 2;    --0=>no,       1=>yes/extended,  2=>switchable with CPU(0)
      extAddr_Mode : integer:= 2;      --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Mode : integer := 2;         --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,  
      DIV_Mode : integer := 2;         --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,  
      BitField : integer := 2;         --0=>no,       1=>yes,           2=>switchable with CPU(1) 
      
      BarrelShifter : integer := 2;    --0=>no,       1=>yes,           2=>switchable with CPU(1)  
      MUL_Hardware : integer := 1      --0=>no,       1=>yes,  
   );
   port(
      CPU            : in std_logic_vector(1 downto 0):="01";  -- 00->68000  01->68010  11->68020
      clk            : in std_logic;
      nReset         : in std_logic:='1';    --low active
      clkena_in      : in std_logic:='1';
      data_in        : in std_logic_vector(15 downto 0);
      IPL            : in std_logic_vector(2 downto 0):="111";
      IPL_autovector : in std_logic:='0';
      addr_out       : out std_logic_vector(31 downto 0);
      berr           : in std_logic:='0';     -- only 68000 Stackpointer dummy for Atari ST core
      FC             : out std_logic_vector(2 downto 0);
      data_write     : out std_logic_vector(15 downto 0);
      busstate       : out std_logic_vector(1 downto 0);	
      nWr            : out std_logic;
      nUDS, nLDS     : out std_logic;
      nResetOut      : out std_logic;
      skipFetch      : out std_logic
--      longword       : out std_logic;
--      clr_berr       : out std_logic;
   );
   END COMPONENT;



   SIGNAL data_write  : std_logic_vector(15 downto 0);
   SIGNAL r_data      : std_logic_vector(15 downto 0);
   SIGNAL cpuIPL      : std_logic_vector(2 downto 0);
   SIGNAL data_akt_s  : std_logic;
   SIGNAL data_akt_e  : std_logic;
   SIGNAL as_s        : std_logic;
   SIGNAL as_e        : std_logic;
   SIGNAL uds_s       : std_logic;
   SIGNAL uds_e       : std_logic;
   SIGNAL lds_s       : std_logic;
   SIGNAL lds_e       : std_logic;
   SIGNAL rw_s        : std_logic;
   SIGNAL rw_e        : std_logic;
   SIGNAL vpad        : std_logic;
   SIGNAL waitm       : std_logic;
   SIGNAL clkena_e    : std_logic;
   SIGNAL S_state     : std_logic_vector(1 downto 0);
   SIGNAL decode      : std_logic;
   SIGNAL wr          : std_logic;
   SIGNAL uds_in      : std_logic;
   SIGNAL lds_in      : std_logic;
   SIGNAL state       : std_logic_vector(1 downto 0);
   SIGNAL clkena      : std_logic;
   SIGNAL skipFetch   : std_logic;
   SIGNAL nResetOut   : std_logic;
   SIGNAL autovector  : std_logic;
   SIGNAL cpu1reset   : std_logic;
   -- Real-hardware fix, part 2 (docs/ROADMAP.md): the ext_force_run fix
   -- for cpu1reset only covers the kernel's own reset input -- this
   -- architecture's OWN bus-cycle state machine below (S_state/as_s/
   -- rw_s/... and the falling-edge as_e/rw_e/clkena_e/... pair) uses the
   -- raw, still-tri-state-resolved `RESET` signal directly as an async
   -- reset condition, completely separate from cpu1reset. If RESET is
   -- stuck low (same root cause as cpu1reset was), this state machine
   -- never leaves its own reset state, AS never asserts, and the CPU can
   -- never start a single bus cycle -- even once the kernel itself is
   -- correctly out of reset. Same fix, same reasoning: a new,
   -- single-driver signal ORing in ext_force_run, not touching RESET's
   -- own tri-state driver at all.
   SIGNAL effective_reset : std_logic;


   type sync_state_t is (sync0, sync1, sync2, sync3, sync4, sync5, sync6, sync7, sync8, sync9);
   signal sync_state : sync_state_t;

BEGIN  
   DATA <= data_write WHEN data_akt_e='1' OR data_akt_s='1' ELSE "ZZZZZZZZZZZZZZZZ";
   AS <= as_s AND as_e;
   RW <= rw_s AND rw_e;
   UDS <= uds_s AND uds_e;
   LDS <= lds_s AND lds_e;
   
   RESET <= '0' WHEN nResetOut='0' ELSE 'Z';
   HALT <=  '0' WHEN nResetOut='0' ELSE 'Z';
   cpu1reset <= (RESET OR HALT) OR ext_force_run;  -- see ext_force_run's own header comment
   effective_reset <= RESET OR ext_force_run;  -- see effective_reset's own declaration comment

cpu1: TG68KdotC_Kernel 
   generic map(
      SR_Read => 2,              --0=>user,     1=>privileged,    2=>switchable with CPU(0)
      VBR_Stackframe => 2,       --0=>no,       1=>yes/extended,  2=>switchable with CPU(0)
      extAddr_Mode => 2,         --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Mode => 2,             --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,  
      DIV_Mode => 2,             --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,  
      BitField => 2,             --0=>no,       1=>yes,           2=>switchable with CPU(1) 

      BarrelShifter => 0,        --0=>no,       1=>yes,           2=>switchable with CPU(1)  
      MUL_Hardware => 1          --0=>no,       1=>yes,  
   )
   PORT MAP(
      CPU => CPU,                -- : in std_logic_vector(1 downto 0):="01";  -- 00->68000  01->68010  11->68020
      clk => CLK,                -- : in std_logic;
      nReset => cpu1reset,       -- : in std_logic:='1';       --low active
      clkena_in => clkena,       -- : in std_logic:='1';
      data_in => r_data,         -- : in std_logic_vector(15 downto 0);
      IPL => cpuIPL,             -- : in std_logic_vector(2 downto 0):="111";
      IPL_autovector => autovector, -- : in std_logic:='0';
      addr_out => ADDR,          -- : buffer std_logic_vector(31 downto 0);
      berr => BERR,              -- : in std_logic:='0';     -- only 68000 Stackpointer dummy for Atari ST core
      FC => FC,                  -- : out std_logic_vector(2 downto 0);
      data_write => data_write,  -- : out std_logic_vector(15 downto 0);
      busstate => state,         -- : buffer std_logic_vector(1 downto 0);	
      nWr => wr,                 -- : out std_logic;
      nUDS => uds_in,            -- : out std_logic;
      nLDS => lds_in,            -- : out std_logic;
      nResetOut => nResetOut,    -- : out std_logic;
      skipFetch => skipFetch     -- : out std_logic
   );
 
   PROCESS (CLK)
   BEGIN
      IF falling_edge(CLK) THEN
        IF ext_clkena_f='1' THEN   -- delayed enable, see ext_clkena_f
         IF sync_state=sync5 THEN
            E <= '1';
         END IF;
         IF sync_state=sync9 THEN
            E <= '0';
         END IF;
        END IF;
      END IF;

      IF rising_edge(CLK) THEN
        IF ext_clkena='1' THEN
         CASE sync_state IS
            WHEN sync0  => sync_state <= sync1;
            WHEN sync1  => sync_state <= sync2;
            WHEN sync2  => sync_state <= sync3;
            WHEN sync3  => sync_state <= sync4;
                        VMA <= VPA;
                        vpad <= VPA;
                        autovector <= NOT VPA;
            WHEN sync4  => sync_state <= sync5;
            WHEN sync5  => sync_state <= sync6;
            WHEN sync6  => sync_state <= sync7;
            WHEN sync7  => sync_state <= sync8;
            WHEN sync8  => sync_state <= sync9;
            WHEN OTHERS => sync_state <= sync0;
                        VMA <= '1';
         END CASE;
        END IF;
      END IF;
   END PROCESS;


   PROCESS (state, clkena_e, skipFetch, ext_clkena)
   BEGIN
      -- ext_clkena gates the kernel here; the two clocked processes below
      -- are gated at their own clock edges. See ext_clkena's port comment.
      IF ext_clkena='1' AND (state="01" OR clkena_e='1' OR skipFetch='1') THEN
         clkena <= '1';
      ELSE
         clkena <= '0';
      END IF;
   END PROCESS;

PROCESS (CLK, effective_reset, state, as_s, as_e, rw_s, rw_e, uds_s, uds_e, lds_s, lds_e)
   BEGIN
      IF effective_reset='0' THEN
         S_state <= "11";
         as_s <= '1';
         rw_s <= '1';
         uds_s <= '1';
         lds_s <= '1';
         data_akt_s <= '0';
      ELSIF rising_edge(CLK) THEN
        IF ext_clkena='1' THEN
         as_s <= '1';
         rw_s <= '1';
         uds_s <= '1';
         lds_s <= '1';
         data_akt_s <= '0';
         CASE S_state IS
            WHEN "00" =>
                      IF state/="01" AND skipFetch='0' THEN
                         IF wr='1' THEN
                            uds_s <= uds_in;
                            lds_s <= lds_in;
                         END IF;
                         as_s <= '0';
                         rw_s <= wr;
                         S_state <= "01";
                      END IF;
            WHEN "01" => 
                      as_s <= '0';
                      rw_s <= wr;
                      uds_s <= uds_in;
                      lds_s <= lds_in;
                      S_state <= "10";
            WHEN "10" =>
                      data_akt_s <= NOT wr;
                      r_data <= DATA;
                      IF waitm='0' OR (vpad='0' AND sync_state=sync9) THEN
                         S_state <= "11";
                      ELSE	
                         as_s <= '0';
                         rw_s <= wr;
                         uds_s <= uds_in;
                         lds_s <= lds_in;
                      END IF;
            WHEN "11" =>
                      S_state <= "00";
            WHEN OTHERS => null;
         END CASE;
        END IF;
      END IF;


      IF effective_reset='0' THEN
         as_e <= '1';
         rw_e <= '1';
         uds_e <= '1';
         lds_e <= '1';
         clkena_e <= '0';
         data_akt_e <= '0';
      ELSIF falling_edge(CLK) THEN
        IF ext_clkena_f='1' THEN   -- delayed enable, see ext_clkena_f
         as_e <= '1';
         rw_e <= '1';
         uds_e <= '1';
         lds_e <= '1';
         clkena_e <= '0';
         data_akt_e <= '0';
         CASE S_state IS
            WHEN "00" =>
                      cpuIPL <= IPL;      --for HALT command
            WHEN "01" =>
                      data_akt_e <= NOT wr;
                      as_e <= '0';
                      rw_e <= wr;
                      uds_e <= uds_in;
                      lds_e <= lds_in;
            WHEN "10" =>
                      rw_e <= wr;
                      data_akt_e <= NOT wr;
                      cpuIPL <= IPL;
                      waitm <= DTACK;
            WHEN OTHERS =>
                      clkena_e <= '1';
         END CASE;
        END IF;
      END IF;
   END PROCESS;
END;