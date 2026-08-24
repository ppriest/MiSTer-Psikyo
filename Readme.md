# Psikyo core for MiSTer

MiSTer FPGA core for the original Psikyo shooter arcade hardware, built with Quartus Prime
17.0.2 Lite for the DE10-nano.

Phase 1 covers the SH201B/KA302C boards: Samurai Aces / Sengoku Ace, Gun Bird and
Battle K-Road. Strikers 1945 and Tengai (SH403/SH404) are a later phase — they need a
PIC protection FSM and a YMF278B, neither of which exists yet.

## Status

All three Phase 1 games boot and run on real hardware. **There is no sound**, and there are
known video defects; see below. No releases have been published.

Working:

* 68EC020 (TG68K kernel at 16 MHz), Z80 sound CPU wired but silent
* ROM loading from `.mra` for all three games
* Both tilemap layers, sprites, palette, DIP switches, inputs
* Runtime board-variant selection, so one `.rbf` serves all three games
* Scandoubler / gamma / scanline effects, aspect and crop, via `sys/arcade_video.v`
* Rotation and 180° flip over HDMI via the HPS framebuffer

Not working or unverified:

* **No audio** — `AUDIO_L/R` are tied low; jt10/YM2610 is not wired in
* Sprites flicker and can persist between frames (see `docs/sprite_buffering.md`)
* Colours look tinted on Gun Bird and Battle K-Road
* `clk_sys` misses timing by about 0.5 ns
* Rotation has not been confirmed on an HDMI display

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
