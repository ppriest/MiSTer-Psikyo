# jt10 (YM2610) provenance

Vendored from https://github.com/jotego/jt12, commit `1aff35dc6611b2f842666ddacce40734896cb1a4`
(2026-08-17), for use as the YM2610 sound chip on the SH201B/KA302C boards (sngkace/gunbird/
btlkroad). Only the `hdl/` directory (and `LICENSE`) was pulled -- not `cc/`, `cfg/`, `doc/`,
`ise/`, `jt89/`, `octave/`, `out/`, `quartus/`, `sgdk/`, `target/`, `ver/` -- those are jotego's
own build/test/toolchain scaffolding for the jt12 repo as a standalone project, not needed here.
Kept the *entire* `hdl/` directory rather than hand-pruning to jt10's exact dependency graph (74
files, 474KB) -- same reasoning as `rtl/cpu/t80/PROVENANCE.md`'s decision to keep T80's full file
set: avoids having to re-derive the true dependency graph by hand and risk silently dropping
something jt10.v actually needs.

**Correction (2026-08-22): `jt49/` was also excluded by the original vendoring pass above, and
that was a real mistake, not a safe scaffolding trim.** `jt12_top.v` instantiates a module named
`jt49` directly (the SSG/AY-3-8910-compatible tone generator jt10 needs for `use_ssg=1`) -- it
is jt12's own git submodule dependency, not part of the jt12 repo's own `hdl/` tree, so excluding
the `jt49/` subdirectory silently left jt10 unable to elaborate at all. Found while building the
first real jt10 testbench (`sim/jt10_tb/`, see "Status" below) -- `jt49` simply didn't exist
anywhere in this repo. Fixed by vendoring it separately: `rtl/sound/jt49/` (its own
`PROVENANCE.md`), from `https://github.com/jotego/jt49` at commit
`47301ed51374d6d41db4db846b7643fecf75e417` (2026-08-22), GPL-3.0 (same posture as jt10 itself,
no new licensing question). With it in place, the full jt10/jt12_top dependency tree compiles
clean under ModelSim -- see "Status".

**License: GPL-3.0**, not the permissive/LGPL licenses of TG68K.C or T80 -- copyleft, with an
explicit "you are obliged to publish your code if you use mine" provision per the jotego project's
own stated terms. This is a real, meaningfully different licensing posture from this project's
other vendored cores and should be treated as a deliberate choice, not a detail to skim past:
since this is (and is intended to remain) a fully open-source hobby FPGA project, GPL-3.0
compatibility is not expected to be a practical problem, but it does mean the whole core --
not just this module -- inherits GPL-3.0's copyleft obligations once this file is actually
integrated into a build. Author: Jose Tejada Gomez (@topapate).

**Top-level module: `jt10.v`**, a thin wrapper around the shared `jt12_top` engine
(`use_lfo=1, use_ssg=1, num_ch=6, use_pcm=0, use_adpcm=1, JT49_DIV=3`) exposing the actual
YM2610-shaped interface: standard 4-address-line CPU register bus (`din`/`addr[1:0]`/`cs_n`/
`wr_n`/`dout`/`irq_n`, the classic OPN-family register protocol), plus **ADPCM-A and ADPCM-B ROM
interfaces** (`adpcma_addr[19:0]`/`adpcma_bank[4:0]`/`adpcma_roe_n`/`adpcma_data[7:0]` and the
equivalent `adpcmb_*` set) -- real YM2610 hardware has dedicated sample ROMs for these channels,
so this project's sound subsystem will need to wire up SDRAM/ROM banking for them, not just the
FM/SSG side -- **confirmed required**, not optional: checked `psikyo.cpp`'s `ROM_START` blocks
directly rather than assuming. `sngkace` has a `ymsnd:adpcma` region (0x100000, ADPCM-A samples
only). `gunbird` has both `ymsnd:adpcma` (0x100000) and `ymsnd:adpcmb` (0x080000, "DELTA-T
Samples") -- full ADPCM-A+B usage. So the ADPCM ROM interfaces on `jt10.v` are load-bearing for
Phase 1, not a corner this project can cut.

## Status

- [x] Source vendored (with the `jt49` gap above found and fixed)
- [x] Compiles under ModelSim-Altera 10.5b -- the full jt10/jt12_top dependency tree (this
      directory's `hdl/`, minus `alt/`/`deprecated/`, which nothing here instantiates, plus
      `rtl/sound/jt49/hdl/`) compiles with 0 errors, 0 warnings.
- [x] **SSG (jt49) verified against a real, derived-not-assumed frequency reference** --
      `sim/jt10_tb/tb_jt10_ssg.sv`. Drives jt10 through its real CPU register-write protocol
      (the same addr[1:0] latch/data scheme a real sound driver uses) to configure SSG channel A
      for two different tone periods, then measures the actual generated square wave on the real
      `psg_A` output and checks it against a frequency formula derived by reading
      `jt12_div.v`/`jt49_cen.v`/`jt49_div.v` directly (not assumed from a datasheet): with `cen`
      tied high, `clk_en_ssg = clk/4` (div_setting's reset value), `cen16 = clk_en_ssg/8`
      (`CLKDIV=3`, `sel=1`), and the tone divider toggles once per `period` `cen16` ticks, giving
      one full square-wave period = `64 * period` raw clk cycles. Both test cases (period=256 and
      128) matched the formula **exactly** (16384 and 8192 clk cycles, zero error), and their 2:1
      ratio confirmed the relationship independent of the absolute formula. First run actually
      failed at exactly half the expected value in both cases -- a real bug, but in the
      testbench's own `measure_period` task (it spanned only a half-period, falling edge to the
      next rising edge, not a full period), not in jt49; the exact 2x factor and preserved 2:1
      ratio between the two cases were what pointed at a measurement-window bug rather than a
      real one. Fixed and re-verified exact.
- [ ] **FM channel and ADPCM-A/B ROM interface: not yet verified.** Explicitly out of scope for
      this pass -- FM synthesis correctness (envelope curves, operator algorithms, LFO) isn't
      something a simple register-write-and-measure test can validate the way a tone generator's
      frequency can, and needs its own dedicated pass (e.g. a real VGM playback comparison or a
      MAME audio trace), not a token check reported as "verified." A real, open issue was found
      in passing and is NOT yet root-caused: `jt12_top.v`'s `jt10_acc` instantiation
      (`gen_adpcm` block, the ADPCM-A/FM accumulator) throws `** Warning: (vsim-3015) ... Port
      size (14) does not match connection size (1) for port 'op_result'` even though the
      connected wire (`op_result_hd`) is declared `[13:0]` (14 bits) at `jt12_top.v` module
      scope -- upstream code, unrelated to the jt49 fix above, and not exercised by the SSG-only
      test (which passed with an exact match), so it's tracked here rather than either ignored or
      falsely folded into "jt10 is verified."
- [x] Confirmed Phase 1 games exercise the ADPCM-A/B paths (`sngkace`: ADPCM-A only;
      `gunbird`: ADPCM-A + ADPCM-B) -- not optional to implement
- [ ] Synthesizes/fits on the real Cyclone V -- not yet attempted; jt10 isn't instantiated in
      `Psikyo.sv` yet (`ym_din` tied to `0`, see `docs/ROADMAP.md`'s "`Psikyo.sv` top-level
      built" entry), so this is separate from that module's own real Quartus verification.
