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

* **The game slows down under sprite load.** Diagnosed, not yet fixed: `sdram.sv` spends
  10 cycles per 64-bit granule and only 4 of them move data — the other 6 are ACTIVATE +
  tRCD + CAS latency, paid on every transaction because the row is closed and reopened
  each time. The sprite engine's worst pass is ~73,000 transactions, about 61% of total
  bus capacity on its own; tilemaps add ~8% and the CPU ~20%, so the bus runs near 90%
  utilisation and the CPU stalls waiting for instruction fetch. Real hardware cannot do
  this — CPU program ROM and sprite GFX ROM are separate chips there. The fix is 4-bank
  interleaving with open-row tracking; jotego measures 48 -> 126 MB/s from that on the
  same chip, so one SDRAM has roughly 3x the bandwidth needed. Validate against
  `sim/sdram_tb/` (real MT48LC16M16 model) before building.
* **Audio has never been heard.** Z80 and jt10/YM2610 are wired and clocked, but the
  ADPCM-A and ADPCM-B ROM interfaces are not connected — `sdram_arbiter5` has no free
  consumer port and no `ADPCMA_BASE`/`ADPCMB_BASE` regions are defined.
* **Sprite palette lags by one frame.** `sprite_frame_buffer` renders during frame N and
  displays during N+1, while palette RAM is read live, so a scene change flashes
  miscoloured sprites for a frame. Real hardware buffers sprite RAM but draws in real
  time. The principled fix is the per-scanline renderer, which is one line ahead rather
  than one frame.
* **Sprite-vs-tilemap priority is unresolved.** The one-hot test and `pri[] = {0, 0xfc,
  0xfe, 0xff}` are in, but whether the rule is a one-hot mask or a magnitude compare with
  ties going to the sprite is still open. See `compositor.sv`.
* **Some tilemap tiles use the wrong palette.** Tracks VRAM column 0 of each row, appears
  mid-screen with non-zero scroll, so it is not a scroll artefact. `tile_cell_decode`,
  `tilemap_addrgen` and `tilemap_coord` all read correctly on inspection; next step is
  dumping our VRAM at that cell and diffing against MAME rather than more code reading.
* **The line-buffer sprite path is buggy** — renders, but degrades progressively down the
  screen. Parked; see `docs/sprite_buffering.md`.
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
