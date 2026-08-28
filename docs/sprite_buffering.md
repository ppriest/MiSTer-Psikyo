# Sprite buffering: current design and known defects

## Current design

`sprite_render_engine` walks the display list once per frame and writes pixels into
`sprite_frame_buffer`, a double-buffered 320x224 store. Each pixel is
`{present, pixel[4], color[5], priority[2]}` = 12 bits, so the two banks cost
2 x 71680 x 12 = about 1.7 Mbit, on a device with roughly 4 Mbit total.

The `present` bit exists because pixel value alone cannot distinguish "opaque pixel 0" from
"nothing drawn here" — all 16 pixel values are legitimately opaque. It therefore has to be
cleared before each render pass, which is a 71680-cycle walk over the bank.

## Measured budget

Taken from hardware via the debug overlay (`sp_render_max`, row 215):

| | clk cycles | % of frame |
| --- | ---: | ---: |
| worst sprite render pass | 881,632 | 61.5% |
| frame buffer clear | 71,680 | 5.0% |
| one frame @ 85.909 MHz / 59.92 Hz | 1,433,729 | 100% |

Rendering fits comfortably. The artefacts below are **not** caused by the engine failing to
keep up.

## Defect 1: flicker (mid-scanout swap)

`frame_swap` is driven from `sp_frame_done`, so the display bank toggles at whatever moment
rendering finishes — about 61.5% of the way down the *visible* frame. The compositor reads the
display bank continuously during scanout, so the top of the picture comes from one bank and the
bottom from the other. The tear line moves with sprite load, which is what reads as flicker.

## Defect 2: retention (clear overlapping the next pass)

After the swap, the new render bank is cleared. `sprite_frame_buffer` **ignores writes while
`swap_busy`**, so if the clear overlaps the next render pass, that frame's sprites are partly
dropped and stale pixels survive where the clear had not yet reached.

## Defect 3: source records swapped mid-render

`spriteram_dbuf` swaps the CPU-write and engine-read banks at `frame_start`. The engine reads
sprite records across the whole frame, so a pass that overruns has its source data swapped
underneath it and draws two frames' sprites mixed. Independent of the output buffer.

## Mitigation in the tree

`status[43]` ("Sprite swap" on the OSD Debug page) selects the swap policy at runtime:

* `EndOfRender` — default, the behaviour described above
* `FrameStart` — swap at the frame boundary and hold the render start until the clear
  completes, which is what `sprite_frame_buffer`'s own header asks for

Both positions boot and run. It is a runtime switch because an earlier attempt to simply make
this change stopped the core booting, and the cause was never established; a switch makes it an
A/B on one bitstream rather than a rebuild per attempt.

## What actually moved the needle: `$C00008` bit 0

`FrameStart` gave a partial improvement. The large improvement came from something outside this
file entirely — the `$C00008` bit-0 change (`Psikyo.sv`, OSD bit 53). That bit had been tied to
`~vblank`; it is now constant 0.

The connection is that bit 0 is not just a status flag the CPU reads, it is the gate the boot
code spins on **before DMAing sprite RAM**. Tied to `~vblank`, every one of those DMAs was
delayed by up to a full frame, so sprite data reached the renderer late and irregularly. That
was mis-diagnosed here as a buffering defect for some time, and the prediction going in was the
opposite of what happened: constant 0 was expected to make tearing *worse* by moving the DMA
into mid-frame. It made it better.

The lesson is that sprite artefacts were being attributed to the output buffer while the input
side was being throttled. Flicker and ghosting still occur, so there is still something here —
defect 3 (source records swapped mid-render, in `spriteram_dbuf`) is untouched by any of this,
as is the per-sprite attribute decode — but the buffer is no longer the only suspect.

Worth following up: `docs/phase1_memory_map.md` describes `$C00008` as carrying
coin/service/vblank/**z80-nmi-status** inputs. If a bit there is a sound-CPU NMI handshake
rather than a video flag, that would matter for sound -- not yet checked against this angle.
Sound is no longer silent (see `docs/ROADMAP.md`'s "Fix sound" item), but this specific
`$C00008` question was never revisited once the actual root causes turned out to be
elsewhere. Verify against MAME source before acting on it.


## The alternative that was tried: per-scanline line buffers (removed 2026-08-29)

A per-scanline alternative (`sprite_line_engine.sv` + `sprite_line_buffer.sv`, selectable at
runtime via `Sprite buffer = Line`, OSD bit 52) was built and evaluated against the whole-frame
approach above — the motivation being that a line buffer structurally can't suffer defects 1/2
(cleared as it's read, swaps at hblank) and costs a fraction of the BRAM (two 320x12-bit banks
vs. 1.7 Mbit). On hardware it rendered correctly only near the top of the screen, degrading
progressively further down — a shape consistent with a per-line time budget deficit compounding
across lines (budget ~5,470 clk/line, measured worst-case average ~3,900 clk/line, but averages
hide non-uniform sprite density) rather than a decode bug, which would have corrupted every line
equally. Parked at that diagnosis rather than pursued further, and deleted once the frame-buffer
approach was settled on as the one to keep — this section is kept as a record of what was tried
and why, not as a live option.

## Defect 4: sprites briefly visible between scenes -- FIXED

At scene transitions, sprites that should not be on screen flashed up
briefly. First observed on the build with the priority fix but WITHOUT the
sprite-palette snapshot; gone on the snapshot build (20260874), confirmed on
hardware. So it was the palette side of the same transition problem after
all: stale sprite-frame-buffer pixels being recolored by the new scene's
live palette made them READ as wrongly-present sprites, and snapshotting the
sprite palette at frame_start (psikyo_core.sv) removed the visible symptom.
Defects 1-3 above stand on their own evidence and remain tracked.
