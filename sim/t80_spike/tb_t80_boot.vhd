-- T80 boot spike: confirms the vendored T80se core resets, fetches from
-- address 0 (Z80 has no separate reset vector -- PC=0 on reset, unlike
-- 68k's SSP/PC vector fetch), executes a handful of instructions exercising
-- each classic bus cycle type (opcode fetch, immediate fetch, memory write,
-- I/O write), and halts. Combinational single-cycle memory model, no wait
-- states -- same "prove it boots and executes correctly" bar as
-- rtl/cpu/tg68k's Phase 0 spike, just with a much lower prior risk (T80 is
-- the de facto standard MiSTer-devel Z80 core, see PROVENANCE.md).
--
-- Test program (hand-encoded -- Z80 opcodes are simple/well-documented
-- enough that this is low-risk unlike 68k's variable-length encoding, but
-- still double-checked byte by byte before trusting it):
--   0000: 3E 42        LD   A, 0x42
--   0002: 32 00 80     LD   (0x8000), A     -- memory write
--   0005: D3 00        OUT  (0x00), A       -- I/O write
--   0007: 76           HALT

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_t80_boot is
end entity;

architecture sim of tb_t80_boot is

    signal clk     : std_logic := '0';
    signal reset_n : std_logic := '0';

    signal m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n : std_logic;
    signal a  : std_logic_vector(15 downto 0);
    signal di : std_logic_vector(7 downto 0);
    signal d_out : std_logic_vector(7 downto 0);

    type mem_t is array(0 to 255) of std_logic_vector(7 downto 0);
    signal mem : mem_t := (
        0  => x"3E", 1  => x"42",
        2  => x"32", 3  => x"00", 4  => x"80",
        5  => x"D3", 6  => x"00",
        7  => x"76",
        others => x"00"
    );

    signal mem_write_addr : std_logic_vector(15 downto 0) := (others => '0');
    signal mem_write_data : std_logic_vector(7 downto 0)  := (others => '0');
    signal mem_write_seen : boolean := false;

    signal io_write_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal io_write_data : std_logic_vector(7 downto 0) := (others => '0');
    signal io_write_seen : boolean := false;

    signal errors : integer := 0;

begin

    clk <= not clk after 5 ns;

    dut : entity work.T80se
        generic map (
            Mode    => 0,
            T2Write => 0,
            IOWait  => 1
        )
        port map (
            RESET_n => reset_n,
            CLK_n   => clk,
            CLKEN   => '1',
            WAIT_n  => '1',
            INT_n   => '1',
            NMI_n   => '1',
            BUSRQ_n => '1',
            M1_n    => m1_n,
            MREQ_n  => mreq_n,
            IORQ_n  => iorq_n,
            RD_n    => rd_n,
            WR_n    => wr_n,
            RFSH_n  => rfsh_n,
            HALT_n  => halt_n,
            BUSAK_n => busak_n,
            A       => a,
            DI      => di,
            DO      => d_out
        );

    -- combinational read: memory-mapped only (I/O reads not exercised by
    -- this test program), matches MREQ_n low + RD_n low
    di <= mem(to_integer(unsigned(a(7 downto 0)))) when (mreq_n = '0' and rd_n = '0') else x"00";

    -- capture writes (memory and I/O separately, distinguished by MREQ_n/IORQ_n)
    process(clk)
    begin
        if rising_edge(clk) then
            if mreq_n = '0' and wr_n = '0' then
                mem_write_addr <= a;
                mem_write_data <= d_out;
                mem_write_seen <= true;
            end if;
            if iorq_n = '0' and wr_n = '0' then
                io_write_addr <= a(7 downto 0);
                io_write_data <= d_out;
                io_write_seen <= true;
            end if;
        end if;
    end process;

    stim : process
    begin
        reset_n <= '0';
        wait for 40 ns;
        reset_n <= '1';

        -- run long enough for all 4 instructions (8 bytes) to fetch/execute
        -- and HALT to assert (HALT_n low) -- generous margin over T80's
        -- actual cycle count per instruction
        wait for 2000 ns;

        assert halt_n = '0'
            report "FAIL: HALT_n never asserted -- core did not reach HALT"
            severity error;
        if halt_n /= '0' then errors <= errors + 1; end if;

        assert mem_write_seen and mem_write_addr = x"8000" and mem_write_data = x"42"
            report "FAIL: memory write not observed as expected (LD (0x8000),A)"
            severity error;
        if not (mem_write_seen and mem_write_addr = x"8000" and mem_write_data = x"42") then
            errors <= errors + 1;
        end if;

        assert io_write_seen and io_write_addr = x"00" and io_write_data = x"42"
            report "FAIL: I/O write not observed as expected (OUT (0x00),A)"
            severity error;
        if not (io_write_seen and io_write_addr = x"00" and io_write_data = x"42") then
            errors <= errors + 1;
        end if;

        if errors = 0 then
            report "PASS: T80se boots, fetches from 0, executes LD/memory-write/IO-write/HALT correctly";
        else
            report "FAIL: " & integer'image(errors) & " check(s) failed";
        end if;

        wait;
    end process;

end architecture;
