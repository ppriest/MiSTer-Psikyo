# Sprite buffering: current design, known defects, and the alternative

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
rather than a video flag, that would matter for sound, which has never been heard. Verify
against MAME source before acting on it.

## The alternative: per-scanline line buffers

A whole-frame sprite buffer is unusual for this class of hardware. Surveying other cores:

* JTFRAME exposes `JTFRAME_LF_BUFFER` ("line-based frame buffer") and `JTFRAME_LF_ZOOM`, so
  even zoom sprites are handled per-scanline across dozens of cores.
* [Arcade-Tecmo issue 6](https://github.com/MiSTer-devel/Arcade-Tecmo_MiSTer/issues/6) is
  gyurco asking why a line buffer cannot be used, noting that original hardware did not use
  frame buffers and that the approach "consumes huge BRAM resources".
* [Arcade-Cave](https://github.com/MiSTer-devel/Arcade-Cave_MiSTer) is the justified
  exception: CAVE's real hardware has a frame buffer.

For this core, two line buffers would be about 7.7 kbit against the current 1.7 Mbit. More
importantly the defects above stop being possible rather than being sequenced around: a line
buffer is cleared as it is read, so retention cannot occur, and it swaps at hblank, so there is
no mid-scanout tear.

Feasibility from our own measurement: 881,632 / 224 lines is about 3,900 cycles per line,
against roughly 5,470 clk cycles available per line. Worst-case lines would exceed that, which
on real hardware is what per-line sprite limits produce — authentic dropout rather than the
current artefacts.

## Status of the line-buffer path

Built and selectable at runtime as `Sprite buffer = Line` (OSD bit 52), alongside the original
frame-buffer path which remains the default:

* `sprite_line_buffer.sv` — two 320x12-bit banks, swapped at `line_start`, with a 320-cycle
  clear of the render bank while `ready` is low.
* `sprite_line_engine.sv` — per-scanline renderer reusing the verified decode modules. Its
  `S_FIND_ROW` state searches `iy` for the sub-tile row covering `render_line`.

One bug found and fixed before it was ever exercised: `le_start` was gated on `lb_ready`, which
drops at `line_start`, so start and ready were never true together and the path rendered
nothing. It now triggers on the rising edge of `lb_ready`.

### Hardware result: partially working, parked

Sprites render, and are correct near the **top** of the screen, degrading progressively further
down. Parked at this point rather than debugged.

That gradient is the useful part of the observation. A decode bug — wrong attribute field, wrong
palette bits, wrong zoom step — would corrupt every scanline equally, because each line is
decoded independently. Error that grows with scanline number instead points at something
accumulating across lines within a frame, which for this design means the per-line time budget:

* Budget is about 5,470 clk cycles per line (htotal 456 at clk/12), minus 320 for the bank clear.
* The measured worst-case frame render was 881,632 cycles, about 3,900 per line averaged — but
  that is an average, and sprite density is not uniform down the screen.

If the engine cannot finish a line inside its budget, the question is whether the next
`line_start` hard-resynchronises it or leaves it mid-record. If it can be left behind, the
deficit carries into the following line and compounds — which is exactly the shape of the
reported symptom. `le_start` currently triggers on the rising edge of `lb_ready`; what happens
when the engine is *still busy* at `line_start` is the thing to check first.

Second candidate, cheaper to rule out: `S_FIND_ROW` searches `iy` for the sub-tile row covering
`render_line`, so its cost is not constant across the screen.

Note that real hardware does drop sprites when a line is oversubscribed — so some loss low on a
busy screen is authentic, and the bar is matching MAME's dropout, not eliminating it.
