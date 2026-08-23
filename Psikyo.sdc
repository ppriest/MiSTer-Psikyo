derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ---------------------------------------------------------------------------
# No CPU multicycle constraints -- deliberately.
# ---------------------------------------------------------------------------
# rtl/cpu/maincpu.sv drives TG68KdotC_Kernel directly, gated by a real 16 MHz
# clock enable (clkena_in). The kernel is entirely rising-edge, so there are
# no half-cycle paths here to mis-constrain, and a genuine clock enable means
# the Fitter is already told the truth by the netlist.
#
# An earlier version of this file constrained {*TG68K:*|*} with
# set_multicycle_path -setup 2/4. That was actively dangerous: it swept the
# TG68K.vhd wrapper's FALLING-edge registers (as_e, rw_e, uds_e, lds_e,
# clkena_e, data_akt_e, cpuIPL, waitm, E) into the collection and granted
# half-cycle paths (~5.8 ns) up to ~46 ns. The Fitter routes them that slowly,
# the timing report stays clean, and the design fails only on silicon -- and
# two of those registers are waitm (the DTACK sample) and data_akt_e (which
# gates the DATA tri-state). See docs/LESSONS_LEARNED.md.
#
# A multicycle IS needed -- the kernel's register file measures ~19.6 ns
# against an 11.64 ns clock -- but it is now safe to state, for two reasons
# that did not hold before:
#
#   1. The CPU path is TG68KdotC_Kernel only, which is entirely rising-edge
#      (verified: zero falling_edge occurrences). The TG68K.vhd wrapper and
#      its falling-edge registers are no longer instantiated, so there is no
#      half-cycle path left in the CPU for a multicycle to corrupt.
#   2. The relaxation is backed by RTL, not hope. rtl/cpu/maincpu.sv gates
#      the kernel with a real 16 MHz clock enable (ticks 5-6 clk_sys cycles
#      apart), and its acc_ph settle counter guarantees nothing downstream
#      acts before the CPU's ~14 ns address path has settled: writes commit
#      at phase 1, BRAM reads capture at phase 2.
#
# Kernel -> kernel gets 4 (5 is genuinely available; 4 keeps margin against
# the minimum enable gap). Kernel -> anywhere gets 2, matching the settle
# discipline above.
set krn [get_registers {*TG68KdotC_Kernel:*|*}]
if {[get_collection_size $krn] > 0} {
    set_multicycle_path -setup -end 2 -from $krn -to [all_registers]
    set_multicycle_path -hold  -end 1 -from $krn -to [all_registers]

    set_multicycle_path -setup -end 4 -from $krn -to $krn
    set_multicycle_path -hold  -end 3 -from $krn -to $krn
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: no TG68KdotC_Kernel registers matched -- CPU multicycle NOT applied"
}
