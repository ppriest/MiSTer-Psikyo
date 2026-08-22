# jt49 (AY-3-8910-compatible SSG) provenance

Vendored from https://github.com/jotego/jt49, commit `47301ed51374d6d41db4db846b7643fecf75e417`
(2026-08-22), because `jt12_top.v` (the shared engine behind `rtl/sound/jt10/hdl/jt10.v`, this
project's YM2610 core) instantiates a module literally named `jt49` for its embedded SSG channel
when `use_ssg=1` -- which `jt10.v` sets. In the upstream `jt12` repo this is pulled in as its own
git submodule (`.gitmodules`: `[submodule "jt49"] path = jt49 url =
https://github.com/jotego/jt49.git`), not part of `jt12`'s own `hdl/` tree, so `rtl/sound/jt10/
PROVENANCE.md`'s original vendoring pass -- which explicitly excluded a `jt49/` subdirectory as
jt12's own "build/test/toolchain scaffolding" -- excluded the actual functional dependency by
mistake. See that file's own "Correction" note for the full story of how this was found: jt10
simply could not elaborate (module `jt49` undefined) until this was fixed.

Pulled the entire `hdl/` directory (11 files: `jt49.v` plus 6 more at `hdl/` top level, plus 4
under `hdl/filter/`), same "don't hand-prune, avoid silently dropping a real dependency" reasoning
as `rtl/sound/jt10/PROVENANCE.md` and `rtl/cpu/t80/PROVENANCE.md` already use for their own vendored
trees -- doubly warranted here, given hand-pruning is exactly the mistake that caused this file to
need writing in the first place. `hdl/filter/` (`jt49_dcrm.v`/`jt49_dcrm2.v`/`jt49_dly.v`/
`jt49_mave.v`) and `jt49_bus.v` are not actually referenced by `jt12_top.v`'s own instantiation of
`jt49` (confirmed by reading `jt49.v` itself -- it only instantiates `jt49_cen`/`jt49_div`/
`jt49_noise`/`jt49_eg`/`jt49_exp`), so they compile in unused rather than being load-bearing;
kept anyway per the same don't-hand-prune reasoning, and they're inert if genuinely unused.
`jt49`'s own repo has no further nested submodules (`.gitmodules` there is empty), so this is the
complete dependency -- nothing else to chase.

**License: GPL-3.0** (`LICENSE`, vendored verbatim) -- same posture as `jt10`'s own GPL-3.0
already documented in `rtl/sound/jt10/PROVENANCE.md`; no new licensing question, both from the
same author (Jose Tejada Gomez, @topapate).

## Status

- [x] Source vendored (fixing the gap `rtl/sound/jt10/PROVENANCE.md` documents)
- [x] Compiles under ModelSim-Altera 10.5b as part of the full jt10/jt12_top dependency tree --
      see `rtl/sound/jt10/PROVENANCE.md`'s own "Status"
- [x] **Verified as a real tone generator**, not just elaborated: `sim/jt10_tb/tb_jt10_ssg.sv`
      drives channel A through jt10's real register bus and confirms the generated square wave's
      period matches a frequency formula derived directly from this module's own clock-divider
      chain (`jt49_cen.v`'s `CLKDIV`/`sel` handling, `jt49_div.v`'s toggle-every-`period` counter)
      exactly, across two independent period values and their 2:1 ratio -- see
      `rtl/sound/jt10/PROVENANCE.md`'s "Status" for the full writeup (this is jt10's test, since
      jt49 only exists as jt10's embedded SSG in this project, not used standalone).
- [ ] Envelope generator (`jt49_eg.v`) and I/O port (`IOA`/`IOB`) behavior not covered by the
      tone-generator test above -- not needed for Phase 1 (Psikyo's sound driver doesn't appear
      to use the SSG's envelope or I/O-port features from what's been read of `psikyo.cpp` so
      far, but that hasn't been specifically re-confirmed against the driver's actual register
      write sequences yet -- revisit if real gameplay audio sounds wrong once jt10 is wired in).
- [ ] Synthesizes/fits on the real Cyclone V -- not yet attempted, same status as jt10 itself.
