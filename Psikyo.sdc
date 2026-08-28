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

# ---------------------------------------------------------------------------
# T80 sound CPU multicycle -- verified the same way as the TG68K entry above.
# ---------------------------------------------------------------------------
# The failing paths this addresses are T80-internal F/IR ALU-flag paths
# (~12.5 ns against 11.64 ns), reported on every build; marginal Z80 timing
# is also a live suspect for the intermittent audio glitches.
#
#   1. No half-cycle paths to sweep in: zero falling_edge occurrences in
#      rtl/cpu/t80/ (checked file by file), and every clocked process in
#      T80se.vhd / T80.vhd / T80_Reg.vhd is rising-edge gated by CEN/ClkEn
#      (ClkEn = CEN and not BusAck). The one CEN-ungated branch (DIRSet,
#      the save-state direct register load) is tied to its '0' port default
#      by rtl/sound/sound_cpu.sv's instantiation and synthesizes away.
#   2. The relaxation is backed by RTL: cen_4m ticks 21-22 clk_sys cycles
#      apart (Bresenham 44/945, rtl/psikyo_top.sv), so every T80 register
#      output is stable for ~21 cycles between updates.
#
# T80 -> T80 gets 4 (21 is genuinely available; 4 keeps wide margin while
# more than clearing the measured paths). T80 -> anywhere gets 2: the sound
# glue samples the T80's bus pins at full clk rate, and observing a value
# one cycle later costs 1 of the ~21 cycles its fetch/latch handshakes
# actually have. Paths INTO the T80 stay single-cycle (no relaxation needed).
set t80 [get_registers {*|sound_cpu:u_sound|T80se:u_cpu|*}]
if {[get_collection_size $t80] > 0} {
    set_multicycle_path -setup -end 2 -from $t80 -to [all_registers]
    set_multicycle_path -hold  -end 1 -from $t80 -to [all_registers]

    set_multicycle_path -setup -end 4 -from $t80 -to $t80
    set_multicycle_path -hold  -end 3 -from $t80 -to $t80
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: no T80se registers matched -- sound CPU multicycle NOT applied"
}

# ---------------------------------------------------------------------------
# Video pixel-path multicycle: tilemap/sprite pixel data -> palette lookup.
# ---------------------------------------------------------------------------
# The remaining recurring clk_sys violations (~-0.9 ns worst) are pixel-data
# paths into the two palette BRAMs' port-B address registers. Two facts make
# a setup-2 relaxation safe here:
#
#   1. Sources are pixel-cadence: tilemap_line_engine's pixel_index /
#      pixel_color registers update ONLY under ce_pix (1-in-12; verified --
#      reset aside, no other branch writes them; pixel_valid is NOT in the
#      collection because blanking edges clear it at full rate), and the
#      sprite frame buffer's read-bank output transitions only when its
#      ce_pix-cadenced read address does.
#   2. The only consumer of the palette output (rgb -> arcade_video /
#      screen_rotate_two) samples at ce_pix cadence too, so an address that
#      settles 2 clk after the pixel tick instead of 1 is invisible: the
#      lookup result is stable 10 cycles before anything reads it.
#
# Deliberately -from restricted, never a blanket -to the palette BRAMs: the
# sprite-palette snapshot copy FSM (rtl/psikyo_core.sv) drives the same
# port-B address at FULL rate and assumes exactly 1-cycle read latency --
# sweeping its paths into a multicycle would silently corrupt the snapshot.
set vidsrc [get_registers {*|tilemap_line_engine:*|pixel_index[*] *|tilemap_line_engine:*|pixel_color[*] *|sprite_frame_buffer:u_sprite_fb|*}]
set palbram [get_registers {*|dpram:u_palette|* *|dpram:u_palette_snap|*}]
if {[get_collection_size $vidsrc] > 0 && [get_collection_size $palbram] > 0} {
    set_multicycle_path -setup -end 2 -from $vidsrc -to $palbram
    set_multicycle_path -hold  -end 1 -from $vidsrc -to $palbram
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: video pixel-path multicycle NOT applied (empty collection)"
}

# ---------------------------------------------------------------------------
# jt12 FM slot-scan -> phase-generator multicycle (precise, audited regs only)
# ---------------------------------------------------------------------------
# The remaining sound-domain violations are one family: jt12_reg's cur_ch /
# cur_op slot-scan counters -> jt12_pg's stage-II pipeline registers
# (~-0.55 ns). Audited before constraining, same discipline as the T80 and
# TG68K entries above:
#   * jt12_reg.v has exactly two clocked blocks, BOTH under `if (clk_en)`;
#     cur_ch/cur_op update nowhere else.
#   * jt12_pg.v has exactly ONE clocked block, under `if (clk_en)`, holding
#     keycode_II / detune_mod_II / phinc_II.
#   * clk_en is jt12_div's post-prescaler FM cycle enable (cen/6 for the
#     YM2610; cen = ym_cen ~9.4 MHz), so both ends tick ~55 clk_sys apart.
# Collections are deliberately the NAMED registers, not subtree wildcards:
# jt12_reg/jt12_pg contain child instances (jt12_kon, jt12_pg_comb, ...)
# that a `u_reg|*` glob would sweep in unaudited. If a sibling family
# surfaces in a later report, audit it and extend the same way.
# Extended after the first constrained build surfaced the predicted sibling
# families (audited the same way before adding):
#   * jt12_lfo's lfo_mod: updates under `clk_en && zero`; its only full-rate
#     branch is the lfo_en clear, and lfo_en itself changes only on
#     cen-cadenced MMR writes -- every transition is >= cen-spaced.
#   * jt12_pg's stage-II regs as SOURCES (detune_mod_II -> the pg_sum /
#     jt12_sh_rst pipeline): already audited clk_en-gated above.
#   * jt12_sh_rst (u_pad) as a destination: single clocked block, clk_en.
set jtsrc [get_registers {*|jt10:u_ym2610|*jt12_reg:u_reg|cur_ch[*] *|jt10:u_ym2610|*jt12_reg:u_reg|cur_op[*] *|jt10:u_ym2610|*jt12_lfo:*|lfo_mod[*] *|jt10:u_ym2610|*jt12_pg:u_pg|phinc_II[*] *|jt10:u_ym2610|*jt12_pg:u_pg|keycode_II[*] *|jt10:u_ym2610|*jt12_pg:u_pg|detune_mod_II[*]}]
set jtdst [get_registers {*|jt10:u_ym2610|*jt12_pg:u_pg|phinc_II[*] *|jt10:u_ym2610|*jt12_pg:u_pg|keycode_II[*] *|jt10:u_ym2610|*jt12_pg:u_pg|detune_mod_II[*] *|jt10:u_ym2610|*jt12_pg:u_pg|jt12_sh_rst:u_pad|*}]
if {[get_collection_size $jtsrc] > 0 && [get_collection_size $jtdst] > 0} {
    set_multicycle_path -setup -end 2 -from $jtsrc -to $jtdst
    set_multicycle_path -hold  -end 1 -from $jtsrc -to $jtdst
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: jt12 slot-scan multicycle NOT applied (empty collection)"
}
