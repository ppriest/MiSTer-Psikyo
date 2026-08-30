# Psikyo core for MiSTer

MiSTer FPGA core for the original Psikyo shooter arcade hardware, built with Quartus Prime
17.0.2 Lite for the DE10-nano.

Phase 1 covers the SH201B/KA302C boards: Samurai Aces / Sengoku Ace, Gun Bird and
Battle K-Road. 
Phase 2 adds Strikers 1945 and Tengai (SH403/SH404): the PIC16C57 protection device is
simulated the same way MAME simulates it, with the per-set answer table delivered by each
`.mra`, and tile banking driven from the security device's bctrl register -- see
`docs/phase2_sh404.md` for the full analysis.

## Status

The Phase 1 games (Samurai Aces / Sengoku Ace, Gunbird, Battle K-Road) are in good shape,
with minor graphical and audio issues. Strikers 1945 and Tengai are newly wired and under
bring-up. Builds are published in `releases/`.

Details:

* 68EC020 (TG68K kernel at 16 MHz)
* ROM loading from `.mra` for all supported games
* SH403/SH404 security-device simulation (`rtl/cpu/s1945_mcu.sv`) and bctrl tile banking
* Both tilemap layers, sprites, palette, DIP switches, inputs
* Rotation and 180° flip over HDMI via the HPS framebuffer
* CPU pause
* Some improvements to priorities and background clear over MAME (which has regressed over the years)

* **Audio may have residual distortion/crackle.** One confirmed cause was fixed
  2026-08-30: the YM2610 delta-T sample client was never wired through to SDRAM, so the
  channel decoded zeros (buzz) on every earlier build.
* **SH404 audio (Strikers 1945 protected sets, Tengai) is wrong/silent for now.** The
  real sound chip is a YMF278B (OPL4); no FPGA core for it exists, so the YM2610 stands
  in at the same I/O window until one does. The unprotected `s1945n`/`s1945nj` sets use
  a real YM2610 sound program and get correct audio today.
* **Timing on `clk_sys` is close to, but not at, full closure.** Four audited
  multicycle constraint families -- TG68K kernel, T80 sound CPU, video pixel-path into
  the palette lookups, and jt12 slot-scan into the phase generator plus its audited
  siblings -- are recorded, each with its audit reasoning, in `Psikyo.sdc` itself, and
  eliminated their whole violation families (clk_sys TNS fell from roughly -300 to
  single digits). The remaining real violations are the sprite render engine's
  full-rate per-column pixel path (approximately -1.2 ns worst, as it has been for
  months of working builds -- a pipeline stage cutting it was tried 2026-08-29 and
  reached full closure, but visibly regressed scene transitions on real hardware and
  was reverted: correct rendering wins over the last picoseconds), plus milli-ns fit
  noise in the vendored `sys/` scandoubler (which the framework's own `sys_top.sdc`
  does not constrain, and which is inactive on this project's HDMI-framebuffer output
  path) and trivial `jt12_mmr` stragglers.

## Todo

* Hardware verification of S1945/Tengai (MCU handshake, banking, byte order)
* YMF278B (OPL4) core for SH404 audio
* Add hiscore.v, CRT Offset, fast rom loading

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for the
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework this
  project is seeded from, the SDRAM controller (`sdram.sv`, vendored via
  [Arcade-Jackal_MiSTer](https://github.com/MiSTer-devel/Arcade-Jackal_MiSTer) and
  extended here to burst-4 reads — see `rtl/memory/sdram/PROVENANCE.md`), and the
  screen-rotation module (`screen_rotate_two.sv`, taken from
  [Arcade-SKNS_MiSTer](https://github.com/MiSTer-devel/Arcade-SKNS_MiSTer)).
- **Tobias Gubener** ([TobiFlex](https://github.com/TobiFlex)) for
  [TG68K.C](https://github.com/TobiFlex/TG68K.C), the 68EC020 main CPU core.
- **Daniel Wallner** for the **T80** Z80 CPU core, vendored via
  [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) (maintained since by MikeJ and
  the MiSTer-devel community); used as the sound CPU on the SH201B/KA302C boards.
- **Jose Tejada** ([@jotego](https://github.com/jotego)) for
  [jt10](https://github.com/jotego/jt12) (YM2610) and
  [jt49](https://github.com/jotego/jt49) (its embedded AY-3-8910-compatible SSG channel),
  from the JTFRAME family of sound cores.
- The **MAMEdev team** (especially Olivier Galibert, R. Belmont and Luca Elia as well as my own work) for [MAME](https://github.com/mamedev/mame)'s `psikyo.cpp`/
  `psikyo_v.cpp` driver — the reference this core's memory maps, video timing, and
  sprite/tilemap semantics are verified against.

## ROMs

No game ROMs are included in this repository, and none ever will be. Obtaining them is your
responsibility.

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| --- | --- |
| `sys` | MiSTer framework, vendored from the template |
| `rtl` | core source |
| `releases` | `.mra` files, and `.rbf` builds once any are published |
| `docs` | design notes and hard-won debugging lessons |
| `sim` | ModelSim testbenches |
| `scripts` | build/deploy/verification tooling (see below) |
| `debug` | reference traces and captures used as ground truth |

## Tooling

Hardware iteration is automated; see `docs/LESSONS_LEARNED.md` for why each of these exists.

| script | purpose |
| --- | --- |
| `build_staged.py` | build a git-worktree snapshot of HEAD in `build/` (gitignored), so the main tree stays editable mid-build; the log, `output_files/` and a `BUILT_COMMIT` stamp land under `build/`. Default revision is the instrumented `Psikyo_stp` (fitter SEED pinned at 7 -- the default-seed fit did not boot); `--rev Psikyo` for release |
| `mister_hw_test.py` | deploy a `.rbf`, launch a `.mra`, pull a screenshot |
| `deploy_rbf.py` | deploy only if the build actually succeeded |
| `deploy_mra.py` | validate an `.mra`, then copy it |
| `validate_mra.py` | check `.mra` well-formedness and structure |
| `verify_rom_trace.py` | solve a ROM interleave against a hardware trace |
| `decode_trace.py` | decode a debug-overlay capture, saved per settings |
| `decode_vram.py` | extract tilemap VRAM and video registers from a capture |
| `png_census.py` | colour census of a screenshot |

Credentials come from `mister.env` (gitignored), never from committed source.

## Debugging on hardware

The core carries an optional debug overlay that drives internal state onto the video
output, decoded by the scripts above. It is enabled from the OSD's Debug page -- visible
only on instrumented (`Psikyo_stp`) builds: every Debug-page line in the CONF_STR carries
an `H1` prefix, and `status_menumask` bit 1 tracks the `DEBUG_ISSP` macro, so release
builds hide the page. The tracer itself (trace buffers, overlay dump bands) also compiles
out of release builds entirely (`DEBUG_TRACER_EN` tracks the same macro, reclaiming the
BRAM); the non-tracer debug bits (render disable, sprite swap, Sound IRQ, C00008) stay
functional in a release build if set via the `.CFG`. The overlay can dump
tilemap VRAM, the video registers, and a CPU ROM-read trace without rebuilding. It was
built because there was no JTAG on this setup; `docs/LESSONS_LEARNED.md` explains how to
use it without fooling yourself.

JTAG is now available, which makes SignalTap, In-System Sources and Probes, and the
In-System Memory Content Editor usable. Instrumented (`Psikyo_stp`) builds carry a
handful of purpose-built ISSP probes for specific investigations: a tilemap VRAM
write/poke probe (instance `"W"`, `scripts/write_vram1.tcl`) and a spriteram read probe
(instance `"S"`, `scripts/read_spriteram.tcl`), which root-caused the (now fixed)
sprite-vs-tilemap priority bug. A USB video capture device is also available; it is
the right tool for anything temporal (game speed under load, one-frame flashes, flicker),
where the one-shot API screenshots cannot help. Use capture for temporal questions and API
screenshots for pixel-exact ones, since HDMI output is scaled.

