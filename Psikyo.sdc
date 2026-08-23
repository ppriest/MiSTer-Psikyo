derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ---------------------------------------------------------------------------
# TG68K.C runs on a 16 MHz clock enable, not on clk_sys
# ---------------------------------------------------------------------------
# rtl/cpu/maincpu.sv gates the whole TG68K entity with cpu_ce, a Bresenham
# 176/945 enable off the 85.909091 MHz clk_sys (= the real board's 16 MHz
# 68EC020, MAME psikyo.cpp sngkace(), "verified on pcb"). Every clocked
# process inside rtl/cpu/tg68k/TG68K.vhd is gated by that enable via its
# ext_clkena port, so both ends of any CPU-internal register-to-register
# path only ever change on an enable tick, and consecutive ticks are 5 or 6
# clk_sys cycles apart.
#
# TimeQuest cannot infer any of that from a clock enable -- without these
# constraints it analyses the CPU as if it ran at the full 85.909091 MHz and
# reports thousands of violations that cannot occur in hardware. Before the
# enable existed those violations were REAL: a quartus_sta run measured
# TG68KdotC_Kernel's Fmax at 48.74 MHz (setup slack -8.879 ns, TNS
# -21031 ns, every one of the 50 worst paths in the design inside that one
# block). See docs/LESSONS_LEARNED.md.
#
# Two relaxations, deliberately different, applied broad-then-specific so the
# specific one wins where they overlap (later assignment takes precedence).
#
# 1. CPU -> ANYWHERE (setup 2). The CPU's combinational output paths measure
#    ~14 ns, longer than one 11.64 ns clk_sys period, so full-rate logic
#    downstream cannot use them in the first cycle after a CPU step. That is
#    enforced in RTL, not assumed: rtl/cpu/maincpu.sv gates every BRAM write
#    enable on `access_started` and delays `rom_req` by one cycle via
#    `rom_access_d`, so nothing commits a write or issues a memory request
#    until the address and data have had two full clk_sys periods (23.3 ns)
#    to settle. Setup 2 states exactly that guarantee. Do NOT widen this
#    without re-checking that no consumer acts on the first cycle -- the
#    failure mode is a write to a half-settled address, which is silent.
#
# 2. CPU -> CPU (setup 4). Both endpoints are gated by ext_clkena, and
#    consecutive enable ticks are 5 or 6 clk_sys cycles apart, so 5 is
#    genuinely available; 4 keeps margin against the minimum gap.
set tg68k_regs [get_registers {*TG68K:*|*}]
if {[get_collection_size $tg68k_regs] > 0} {
    set_multicycle_path -setup -end 2 -from $tg68k_regs -to [all_registers]
    set_multicycle_path -hold  -end 1 -from $tg68k_regs -to [all_registers]

    set_multicycle_path -setup -end 4 -from $tg68k_regs -to $tg68k_regs
    set_multicycle_path -hold  -end 3 -from $tg68k_regs -to $tg68k_regs
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: no TG68K registers matched -- CPU multicycle constraints NOT applied"
}
