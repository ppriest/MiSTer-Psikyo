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
#      collection because blanking edges clear it at full rate).
#   2. The only consumer of the palette output (rgb -> arcade_video /
#      screen_rotate_two) samples at ce_pix cadence too, so an address that
#      settles 2 clk after the pixel tick instead of 1 is invisible: the
#      lookup result is stable 10 cycles before anything reads it.
#
# Deliberately -from restricted, never a blanket -to the palette BRAMs: the
# palette snapshot copy FSM (rtl/psikyo_core.sv) drives the same port-B
# address at FULL rate and assumes exactly 1-cycle read latency -- sweeping
# its paths into a multicycle would silently corrupt the copy.
#
# This collection used to include sprite_frame_buffer:u_sprite_fb as a
# second source family. That module is retired from synthesis (replaced by
# the per-scanline path, docs/sprite_buffering.md), so the glob matched
# nothing and quietly contributed no exception -- removed rather than left
# as a dead pattern implying coverage that does not exist. Its replacement,
# sprite_line_buffer, is deliberately NOT substituted in: none of its paths
# are failing, and granting slack a path does not need is how a multicycle
# turns into permission for the Fitter to route it slowly. If one surfaces
# in a later report, audit it and add it explicitly, the same way as above.
set vidsrc [get_registers {*|tilemap_line_engine:*|pixel_index[*] *|tilemap_line_engine:*|pixel_color[*]}]
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

# ---------------------------------------------------------------------------
# OPL4 PCM envelope-rate chain -> the registers written in S_ENV
#
# Reported worst clk_sys path after the OPL4 PCM engine landed: -7.677 ns,
# TNS -3900, every top path of the form
#     opl4_pcm|c_rc[3] / c_oct[0]  ->  opl4_pcm|mem_rd_addr[17]
# The DATA into mem_rd_addr is just ch_baseaddr + w_curpos; what is slow is
# that register's ENABLE, which in S_ENV carries the whole envelope
# computation:
#     c_rc,c_oct -> corr -> eff_rate -> cur_rate -> eg_inc
#                -> es_env_next (incl. the (w_env+1)*eg_inc multiply)
#                -> (es_env_next > EG_QUIET) -> the S_ENV fetch/skip branch
#
# Audit (rtl/sound/opl4/opl4_pcm.sv), same discipline as the entries above --
# the cached c_* fields are latched by the slot's gather states and are NOT
# consumed on the very next edge:
#   * The slot FSM advances exactly one state per clk with no waits between
#     S_RD1 and S_ENV: S_RD2 -> S_RD3 -> ... -> S_RD8 -> S_CALC -> S_ENV,
#     each an unconditional single-cycle assignment.
#   * LATEST-updating sources are c_rc/c_rr, latched at the edge ending
#     S_RD8. Their only consumers are corr/slot_rate -> cur_rate, and
#     cur_rate/eg_inc/frac_zero are read ONLY in S_ENV (lines 473-485) --
#     nothing in S_CALC touches them. That is 2 edges (end S_CALC, end
#     S_ENV), so setup 2 is the exact available window, not a guess.
#   * c_sl feeds eg_sustain, which IS read in S_CALC -- latched at the edge
#     ending S_RD7, that is also 2 edges. Still setup 2.
#   * Everything else here is latched earlier still (c_oct in S_RD2, c_fnum
#     in S_RD3, c_ar/c_dr in S_RD6), so 4-8 edges.
# The 1-cycle paths are deliberately NOT included: w_env/w_curpos/w_step/
# w_state_eg are latched in S_CALC and consumed in S_ENV on the very next
# edge, so the (w_env+1)*eg_inc multiply itself stays a full-rate path.
# Sources are the NAMED cached registers, never an opl4_pcm|* glob, so the
# single-cycle w_* family cannot be swept in by accident.
set pcmsrc [get_registers {*|opl4_pcm:u_pcm|c_rc[*] *|opl4_pcm:u_pcm|c_rr[*] *|opl4_pcm:u_pcm|c_ar[*] *|opl4_pcm:u_pcm|c_dr[*] *|opl4_pcm:u_pcm|c_sl[*] *|opl4_pcm:u_pcm|c_sr[*] *|opl4_pcm:u_pcm|c_oct[*] *|opl4_pcm:u_pcm|c_fnum[*] *|opl4_pcm:u_pcm|c_damp}]
set pcmdst [get_registers {*|opl4_pcm:u_pcm|mem_rd_addr[*] *|opl4_pcm:u_pcm|mem_rd_req *|opl4_pcm:u_pcm|state[*] *|opl4_pcm:u_pcm|ch_env[*] *|opl4_pcm:u_pcm|ch_eg_state[*] *|opl4_pcm:u_pcm|ch_nextpos[*] *|opl4_pcm:u_pcm|ch_tl[*] *|opl4_pcm:u_pcm|ch_lfo[*] *|opl4_pcm:u_pcm|w_step[*]}]
if {[get_collection_size $pcmsrc] > 0 && [get_collection_size $pcmdst] > 0} {
    set_multicycle_path -setup -end 2 -from $pcmsrc -to $pcmdst
    set_multicycle_path -hold  -end 1 -from $pcmsrc -to $pcmdst
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: OPL4 PCM envelope multicycle NOT applied (empty collection)"
}

# ---------------------------------------------------------------------------
# OPL4 PCM output accumulate -> acc_l / acc_r
#
# With the envelope family above constrained, every remaining violated
# clk_sys path (all 400 sampled) converges on one destination family:
# opl4_pcm's acc_l/acc_r. S_OUT does two multiplies and two table lookups in
# a single cycle:
#     c_amd -> am_depth_f -> (* lfo_tri) -> am_add ---+
#     ch_env, ch_tl[16:8] ----------------------------+-> os_env_eff
#     c_pan -> pan_att_l/r -> pan_l/r ----------------+-> os_lenv/os_renv
#          -> att2vol -> os_lvol/os_rvol -> (* w_sample) -> acc_l/acc_r
#
# Audit (rtl/sound/opl4/opl4_pcm.sv). S_OUT is reachable only via
# S_CALC -> S_ENV -> S_FETCH0 [-> S_FETCH1] -> S_OUT, one state per clk:
#   * c_amd and w_lfo are latched at the edge ending S_CALC -> 3 edges to
#     S_OUT. c_pan is latched back in S_RD1, so more still.
#   * ch_env and ch_tl are written in S_ENV -> 2 edges to S_OUT. Their only
#     earlier readers are the next channel's S_RD1/S_CALC, a whole slot
#     later.
#   * am_add, pan_l and pan_r are read ONLY in S_OUT -- nothing consumes
#     them a cycle after their sources are latched.
# So 2 is the tightest available window across the listed sources; setup 2
# doubles the budget, which is enough for a path measured at ~19 ns.
#
# w_sample is deliberately EXCLUDED as a source: it is written in
# S_FETCH0/S_FETCH1 and consumed in S_OUT on the very next edge, so the
# final multiply stays a full-rate path. acc_l/acc_r as sources are likewise
# excluded -- listing only the named registers keeps that single-cycle
# feedback out of the exception.
set accsrc [get_registers {*|opl4_pcm:u_pcm|c_amd[*] *|opl4_pcm:u_pcm|c_pan[*] *|opl4_pcm:u_pcm|w_lfo[*] *|opl4_pcm:u_pcm|ch_env[*] *|opl4_pcm:u_pcm|ch_tl[*]}]
set accdst [get_registers {*|opl4_pcm:u_pcm|acc_l[*] *|opl4_pcm:u_pcm|acc_r[*]}]
if {[get_collection_size $accsrc] > 0 && [get_collection_size $accdst] > 0} {
    set_multicycle_path -setup -end 2 -from $accsrc -to $accdst
    set_multicycle_path -hold  -end 1 -from $accsrc -to $accdst
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: OPL4 PCM accumulate multicycle NOT applied (empty collection)"
}

# ---------------------------------------------------------------------------
# HQ2x scandoubler blender (sys/hq2x.sv) -- ce_x4 cadence
# ---------------------------------------------------------------------------
# With every core-RTL family above constrained, the only clk_sys paths still
# failing are 12 inside the framework's HQ2x blender, all Blend-internal
# (df_rule -> i30 and friends, ~-0.1 ns). sys/ is vendored and not ours to
# edit, and hq2x cannot be compiled out: sys/scandoubler.v's disable_hq2x is
# a RUNTIME input (~hq2x from the OSD), and there is no parameter or `ifdef`
# anywhere in hq2x.sv / scandoubler.v / video_mixer.sv / arcade_video.v. So
# the blender is synthesized regardless of the Scandoubler Fx setting, and
# the only lever left on our side of the boundary is this constraint.
#
# Audit (sys/hq2x.sv module Blend), same discipline as the entries above:
#   * EVERY clocked block in Blend is `always @(posedge clk) if (clk_en)` --
#     all four of them (the a/b/d/e/h/f + bl_rule/df_rule latch, the i10/
#     i20/i30 + op0 case, the i1/i2/i3 + op pipeline, and Result). There is
#     no ungated branch and no falling-edge logic in the module at all, so
#     there is nothing here of the kind that made the old TG68K multicycle
#     dangerous.
#   * clk_en is the scandoubler's ce_x4i. arcade_video is instantiated with
#     .clk_video(clk_sys) (Psikyo.sv), and our ce_pix is clk_sys/12, so
#     sys/scandoubler.v measures pixsz=12 and pulses ce_x4i at pc_in ==
#     pixsz4(3), pixsz2(6), pixsz2+pixsz4(9) and pixsz(12): once every 3
#     clk_sys cycles, i.e. ~34.9 ns of real settling time against the 11.64
#     ns the analyzer is currently demanding.
#
# THE EXCEPTION, stated plainly rather than buried. That 3-cycle spacing is
# not unconditional: scandoubler.v also forces an enable on hsync,
#
#     if((~hs & hs_in) || (pc_in >= pixsz)) begin ce_x4i <= 1; ...
#
# so an hsync rising edge landing one cycle after a regular pulse produces
# two enables back to back, and for that ONE transition per scanline a
# setup-2 exception is not backed by the hardware. It is accepted here
# because the affected samples are hsync-time blanking pixels -- Blend is
# four enable-stages deep, so the disturbance stays inside hsync and never
# reaches a displayed pixel -- and because it can only ever affect the HQ2x
# Fx setting, not the default or CRT scanline modes. If HQ2x output ever
# shows an artifact at the left edge of the picture, THIS is the first thing
# to suspect, and the fix is to drive clk_video from a slower dedicated PLL
# output instead (the structurally correct fix, deferred as real work).
#
# Scoped Blend-internal only: the failing paths are all inside it, and the
# rule/pattern logic feeding it from hq2x_in runs on the same enable but has
# not been audited here, so it is deliberately left at full rate.
set blend [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
if {[get_collection_size $blend] > 0} {
    set_multicycle_path -setup -end 2 -from $blend -to $blend
    set_multicycle_path -hold  -end 1 -from $blend -to $blend
} else {
    post_message -type critical_warning \
        "Psikyo.sdc: no HQ2x Blend registers matched -- blender multicycle NOT applied"
}
