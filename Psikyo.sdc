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
# If a multicycle is ever needed again, scope it to a block verified to be
# single-edge and remove_from_collection every falling-edge register from
# BOTH ends.
