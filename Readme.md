# Psikyo core for MiSTer

MiSTer FPGA core for the original Psikyo shooter arcade hardware, built with Quartus Prime
17.0.2 Lite for the DE10-nano.

Phase 1 covers the SH201B/KA302C boards: Samurai Aces / Sengoku Ace, Gun Bird and
Battle K-Road. Strikers 1945 and Tengai (SH403/SH404) are a later phase — they need a
PIC protection FSM and a YMF278B, neither of which exists yet.

## Status

All three Phase 1 games boot and run on real hardware. Known defects remain in audio and
in game speed under sprite load; see below. Builds are published in `releases/`.

Working, confirmed on hardware:

* 68EC020 (TG68K kernel at 16 MHz)
* ROM loading from `.mra` for all three games
* Both tilemap layers, sprites, palette, DIP switches, inputs
* Runtime board-variant selection, so one `.rbf` serves all three games
* Scandoubler / gamma / scanline effects via `sys/arcade_video.v`
* Rotation and 180° flip over HDMI via the HPS framebuffer
* CPU pause, and the debug overlay used for bring-up
* DIP switches, delivered via ioctl index 254 as MiSTer actually sends them
* Sprite RAM buffered as a true copy at vblank, matching buffered_spriteram32_device --
  this fixed sprite ghosting, stale sprites, and Gun Bird's per-scene sprite freeze
* Sprite-vs-tilemap priority. The `primask` table (`{0, 0xFC, 0xFE, 0xFF}`, entry 2
  corrected from MAME's published `0xFF` by the author of MAME's Psikyo renderer) is
  applied BIT-INDEXED by the destination priority value -- MAME's pdrawgfx convention.
  An earlier value-AND implementation let priority-1 sprites beat tilemap 1
  unconditionally (samuraia's cloud sprites over the foreground layer); root-caused by
  dumping the live paused scene through the JTAG spriteram probe (instance `"S"`,
  `scripts/read_spriteram.tcl`).
* Scene transitions. Sprites display pixels rendered one frame earlier, so they read a
  512-entry snapshot of their palette half, copied at `frame_start`
  (`rtl/psikyo_core.sv`), so sprite pixels and colors change scene together; tilemaps
  render live and keep the live palette. This fixed BOTH transition symptoms: the
  miscolour flash AND the briefly-visible stale sprites (stale pixels recolored by the
  new scene's palette had read as wrongly-present sprites).

Not working, or built but unconfirmed:

* **The game slows down under sprite load.** Still open; a first attempted fix measured
  worse, not better, on real hardware. The memory backend is Sorgelig's `sdram.sv`
  (vendored, extended to burst-4 reads — see `rtl/memory/sdram/PROVENANCE.md`) behind a
  3-physical-port arbiter — current partition: both tilemap layers share one port,
  sprite gfx has a dedicated port, and a 6-way arbitrated port serves
  spritelut/CPU fetches/ADPCM samples/HPS download (`docs/phase1_sdram_map.md`). A
  granule cache in `sdram_narrow_bridge.sv` cut narrow-consumer (CPU/Z80/spritelut)
  traffic on the shared port. The re-partition itself (sprite gfx dedicated, tilemap
  layers merged) measured 29% *worse* worst-case sprite render time on hardware, not
  better; not yet root-caused. See `docs/ROADMAP.md`'s "Fix the slowdown" item.
* **Audio has residual distortion/crackle; cause identified and fix implemented,
  listening verification pending.** Music and sound effects play: a sound-latch decode
  bug, a Z80 running 21x too fast, a spurious ROM re-request, and an SDRAM arbiter
  deadlock are all fixed. Samurai Aces / Sengoku Ace's ADPCM-A bit 6/7 swap
  (`needs_adpcma_swap` in `rtl/memory/psikyo_sdram_top.sv`) is fixed AND verified by
  ear -- the missing piece was `.mra` ordering: the mod byte gating the swap must
  precede the ROM it gates, so all nine `.mra` files were reordered. Samurai Aces'
  missing music is fixed too: the YM2610 timer IRQ must reach the Z80, so Sound IRQ now
  defaults ON (`status[51]` is inverted; OSD order "On,Off"). A listening test on the
  fully-constrained build (20260876) confirms the remaining distortion/crackle is NOT a
  timing artifact. Identified cause: jt10's ADPCM-B (delta-T) data input was hardwired
  to zero (`.adpcmb_data(8'd0)`, `rtl/psikyo_top.sv`), so any track using the delta-T
  channel decoded constant zeros and mixed garbage into the output -- on these boards
  ADPCM-B shares the ADPCM-A sample region (MAME's YM2610 default when no separate
  delta-T ROM exists). The channel is now wired to that SDRAM region (testbench
  regression passing); verification by ear on hardware is pending.
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
- **rmonic79** for [Arcade-Raiden_MiSTer](https://github.com/rmonic79/Arcade-Raiden_MiSTer),
  cross-checked for arcade-specific `sys/` wiring conventions (joystick/button index
  mapping).
- The **MAMEdev team** for [MAME](https://github.com/mamedev/mame)'s `psikyo.cpp`/
  `psikyo_v.cpp` driver — the reference this core's memory maps, video timing, and
  sprite/tilemap semantics are verified against.
