# Psikyo core for MiSTer

MiSTer FPGA core for the original Psikyo shooter arcade hardware, built with Quartus Prime
17.0.2 Lite for the DE10-nano.

Phase 1 covers the SH201B/KA302C boards: Samurai Aces / Sengoku Ace, Gun Bird and
Battle K-Road. Strikers 1945 and Tengai (SH403/SH404) are a later phase — they need a
PIC protection FSM and a YMF278B, neither of which exists yet.

## Status

All three Phase 1 games boot and run on real hardware. There are known video, audio and
speed defects; see below. Builds are published in `releases/`.

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

Not working, or built but unconfirmed:

* **The game slows down under sprite load.** Still open; a first attempted fix measured
  worse, not better, on real hardware. The memory backend is Sorgelig's `sdram.sv`
  (vendored, extended to burst-4 reads — see `rtl/memory/sdram/PROVENANCE.md`) behind a
  3-physical-port arbiter: dedicated ports for each tilemap layer, a 5-way arbitrated
  port for sprite gfx/lut/CPU fetch/HPS download (`docs/phase1_sdram_map.md`). A granule
  cache in `sdram_narrow_bridge.sv` cut narrow-consumer (CPU/Z80/spritelut) traffic on
  the shared port. A follow-up re-partition -- a dedicated port for sprite gfx, both
  tilemap layers sharing one port -- measured 29% *worse* worst-case sprite render time
  on hardware, not better; not yet root-caused. See `docs/ROADMAP.md`'s "Fix the
  slowdown" item.
* **Audio is not yet correct.** No longer silent: a sound-latch decode bug, a Z80 running
  21x too fast, a spurious ROM re-request, and an SDRAM arbiter deadlock are all fixed,
  and hardware now produces nonzero audio output with commands streaming during play.
  ADPCM-A sample playback is still garbled on every game. A required bit 6/7 swap on the
  ADPCM-A sample ROM (a real ROM-mastering artefact, `needs_adpcma_swap` in
  `rtl/memory/psikyo_sdram_top.sv`) is implemented for Samurai Aces/Sengoku Ace, which
  need it -- but Gun Bird, which MAME says does *not* need the swap, is garbled too, so a
  second, unidentified cause remains open. YM2610 clock frequency and the SDRAM
  granule-cache handshake have both been checked and ruled out.
* **Sprite palette lags by one frame.** `sprite_frame_buffer` renders during frame N and
  displays during N+1, while palette RAM was read live, so a scene change could flash
  miscoloured sprites for a frame. Fixed: sprites read a 512-entry snapshot of their
  palette half, copied at `frame_start` (`rtl/psikyo_core.sv`), so sprite pixels and
  colors change scene together; tilemaps render live and keep the live palette.
* **Sprite-vs-tilemap priority: fixed, verified on hardware.** The `primask` table
  (`{0, 0xFC, 0xFE, 0xFF}`, entry 2 corrected from MAME's published `0xFF` by the
  author of MAME's Psikyo renderer) is applied BIT-INDEXED by the destination priority
  value -- MAME's pdrawgfx convention. An earlier value-AND implementation let
  priority-1 sprites beat tilemap 1 unconditionally (samuraia's cloud sprites over the
  foreground layer); root-caused by dumping the live paused scene through the JTAG
  spriteram probe (instance `"S"`, `scripts/read_spriteram.tcl`).
* **Timing is not closed.** Worst-case setup slack on the main PLL output (`clk_sys`) is
  negative, with many failing paths rather than one -- see `docs/ROADMAP.md`'s "Timing
  closure not final" item for the current worst-slack figure and offending path (it
  moves as work lands elsewhere in the design, so it's tracked there rather than
  duplicated here). The core runs anyway, but the margin is thin enough that unrelated
  logic changes can tip it. It also blocks raising the SDRAM clock, which would
  otherwise be worth ~1.12x.

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
output, decoded by the scripts above. It is enabled from the OSD's Debug page and can dump
tilemap VRAM, the video registers, and a CPU ROM-read trace without rebuilding. It was
built because there was no JTAG on this setup; `docs/LESSONS_LEARNED.md` explains how to
use it without fooling yourself.

JTAG is now available, which makes SignalTap, In-System Sources and Probes, and the
In-System Memory Content Editor usable. Instrumented (`Psikyo_stp`) builds carry a
handful of purpose-built ISSP probes for specific investigations: a tilemap VRAM
write/poke probe (instance `"W"`, `scripts/write_vram1.tcl`) and a spriteram read probe
(instance `"S"`, `scripts/read_spriteram.tcl`), currently in use for the open
sprite-vs-tilemap priority bug above. A USB video capture device is also available; it is
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
