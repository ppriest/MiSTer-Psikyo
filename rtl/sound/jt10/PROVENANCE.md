# jt10 (YM2610) provenance

Vendored from https://github.com/jotego/jt12, commit `1aff35dc6611b2f842666ddacce40734896cb1a4`
(2026-08-17), for use as the YM2610 sound chip on the SH201B/KA302C boards (sngkace/gunbird/
btlkroad). Only the `hdl/` directory (and `LICENSE`) was pulled -- not `cc/`, `cfg/`, `doc/`,
`ise/`, `jt49/`, `jt89/`, `octave/`, `out/`, `quartus/`, `sgdk/`, `target/`, `ver/` -- those are
jotego's own build/test/toolchain scaffolding for the jt12 repo as a standalone project, not
needed here. Kept the *entire* `hdl/` directory rather than hand-pruning to jt10's exact
dependency graph (74 files, 474KB) -- same reasoning as `rtl/cpu/t80/PROVENANCE.md`'s decision
to keep T80's full file set: avoids having to re-derive the true dependency graph by hand and
risk silently dropping something jt10.v actually needs.

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

- [x] Source vendored
- [ ] Compiles under ModelSim-Altera 10.5b
- [ ] Verified against a known-good reference (e.g. VGM playback comparison, or MAME audio trace)
      -- **not yet attempted**. This is a substantially bigger undertaking than T80's or
      TG68K.C's boot spikes (FM synthesis correctness isn't something a simple
      instruction-execution check can validate) and deserves its own dedicated pass rather than
      a token compile-only check reported as "verified."
- [x] Confirmed Phase 1 games exercise the ADPCM-A/B paths (`sngkace`: ADPCM-A only;
      `gunbird`: ADPCM-A + ADPCM-B) -- not optional to implement
- [ ] Synthesizes/fits on the real Cyclone V
