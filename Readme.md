# Psikyo core for MiSTer

MiSTer FPGA core for the original Psikyo shooter arcade hardware, built with Quartus Prime
17.0.2 Lite for the DE10-nano.

Phase 1 covers the SH201B/KA302C boards: Samurai Aces / Sengoku Ace, Gun Bird and
Battle K-Road. Strikers 1945 and Tengai (SH403/SH404) are a later phase — they need a
PIC protection FSM and a YMF278B, neither of which exists yet.

## Status

All three Phase 1 games boot and run on real hardware. There are known video, audio and
speed defects; see below. No releases have been published.

Working, confirmed on hardware:

* 68EC020 (TG68K kernel at 16 MHz)
* ROM loading from `.mra` for all three games
* Both tilemap layers, sprites, palette, DIP switches, inputs
* Runtime board-variant selection, so one `.rbf` serves all three games
* Scandoubler / gamma / scanline effects via `sys/arcade_video.v`
* Rotation and 180° flip over HDMI via the HPS framebuffer
* CPU pause, and the debug overlay used for bring-up

Not working, or built but unconfirmed:

* **Audio has never been heard.** Z80 and jt10/YM2610 are wired and clocked, but the ADPCM-A
  and ADPCM-B ROM interfaces are not connected — `sdram_arbiter5` has no free consumer port,
  and no `ADPCMA_BASE`/`ADPCMB_BASE` regions are defined. FM only, at best.
* **The game intermittently slows down.** Not the uniform half-speed that the `$C00008` bit-0
  change addressed — that change is in and the slowdown outlives it. Leading hypothesis is
  SDRAM contention: `sdram_arbiter5` is strict round-robin and fully serialises one
  transaction at a time, so a heavy sprite frame takes slots away from CPU instruction fetch.
  Untested; OSD bit 40 (Sprites Off) is the discriminating experiment.
* **Sprites still flicker and ghost**, improved but not fixed by `Sprite swap = FrameStart`.
  The per-scanline replacement is built and selectable (OSD bit 52) but has not been
  evaluated. See `docs/sprite_buffering.md`.
* Some tilemap tiles use the wrong palette (a row of the Gun Bird logo goes green); the
  sengokua hiscore tilemap is offset by about two tiles.
* Gun Bird sprites freeze a few seconds into each scene — suspected spriteram banking.
* Aspect ratio Original/Full Screen: the rotation-aware fix is built but not confirmed.
* `clk_sys` misses timing by about 0.45 ns.

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

There is no JTAG on this setup. The core carries an optional debug overlay that drives
internal state onto the video output, decoded by the scripts above. It is enabled from the
OSD's Debug page and can dump tilemap VRAM, the video registers, and a CPU ROM-read trace
without rebuilding. `docs/LESSONS_LEARNED.md` explains how to use it without fooling yourself.
