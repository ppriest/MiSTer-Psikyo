-------------------------------------------------------------------------------
-- Standalone synthesis-check top level for TG68K.C, targeting the DE10-nano's
-- actual Cyclone V (5CSEBA6U23I7) via Quartus 17.0.2. Not part of the core's
-- real top-level (see Template.qsf/sys/ for that) -- this exists purely to
-- answer "does the vendored CPU synthesize on the real device" (Phase 0,
-- see rtl/cpu/tg68k/PROVENANCE.md) in isolation from the rest of the design,
-- which doesn't exist yet. Every TG68K port is passed straight through so
-- nothing gets optimized away as unused.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity tg68k_synth_top is
   port(
      CLK    : in std_logic;
      RESET  : inout std_logic;
      HALT   : inout std_logic;
      BERR   : in std_logic;
      IPL    : in std_logic_vector(2 downto 0);
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
end entity;

architecture rtl of tg68k_synth_top is

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

begin

   u_cpu: TG68K
      generic map (CPU => "11")   -- 68020, matches the Phase 0 spike and Psikyo's 68EC020
      port map (
         CLK   => CLK,
         RESET => RESET,
         HALT  => HALT,
         BERR  => BERR,
         IPL   => IPL,
         ADDR  => ADDR,
         FC    => FC,
         DATA  => DATA,
         AS    => AS,
         UDS   => UDS,
         LDS   => LDS,
         RW    => RW,
         DTACK => DTACK,
         E     => E,
         VPA   => VPA,
         VMA   => VMA
      );

end architecture;
