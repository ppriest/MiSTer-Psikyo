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
# CRITICAL: TG68K.vhd's WRAPPER contains FALLING-EDGE registers -- as_e,
# rw_e, uds_e, lds_e, clkena_e, data_akt_e, cpuIPL, waitm and E. A path from
# a rising-edge register into one of those is a HALF-CYCLE path (~5.8 ns at
# 85.909091 MHz), not a full-cycle one.
#
# The first version of these constraints matched {*TG68K:*|*}, which swept
# those registers into both the -from and -to collections and granted them
# 2 or 4 FULL cycles -- up to ~46 ns for a path that physically has 5.8 ns.
# The Fitter is then free to route them arbitrarily slowly, the timing
# report looks clean, and the design fails only on real silicon. That is
# especially damaging here because `waitm <= DTACK` (the CPU's DTACK sample)
# and `data_akt_e` (which gates the DATA tri-state) are both in that set, so
# relaxing them corrupts bus handshaking directly.
#
# TG68KdotC_Kernel is entirely rising-edge (verified: zero falling_edge
# occurrences), and it is the block that actually needs the relaxation --
# its register file is what measured 19.6 ns. So constrain the KERNEL, and
# explicitly exclude the wrapper's falling-edge registers from both ends.
set tg68k_neg [get_registers { *TG68K:*|as_e *TG68K:*|rw_e *TG68K:*|uds_e \
                                *TG68K:*|lds_e *TG68K:*|clkena_e *TG68K:*|data_akt_e \
                                *TG68K:*|cpuIPL* *TG68K:*|waitm *TG68K:*|E }]
set tg68k_krn [get_registers {*TG68KdotC_Kernel:*|*}]

if {[get_collection_size $tg68k_krn] > 0} {
    set krn_src [remove_from_collection $tg68k_krn $tg68k_neg]
    set dst_all [remove_from_collection [all_registers] $tg68k_neg]

    # Kernel -> anywhere (except falling-edge regs): 2 cycles. rtl/cpu/
    # maincpu.sv guarantees nothing acts on the first cycle (BRAM write
    # enables gated on access_started, rom_req delayed by rom_access_d).
    set_multicycle_path -setup -end 2 -from $krn_src -to $dst_all
    set_multicycle_path -hold  -end 1 -from $krn_src -to $dst_all

    # Kernel -> kernel: 4 cycles. Both ends are gated by ext_clkena and
    # consecutive enable ticks are 5-6 clk_sys cycles apart, so 5 is really
    # available; 4 keeps margin against the minimum gap.
    set_multicycle_path -setup -end 4 -from $krn_src -to $krn_src
    set_multicycle_path -hold  -end 3 -from $krn_src -to $krn_src
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: no TG68KdotC_Kernel registers matched -- CPU multicycle constraints NOT applied"
}
