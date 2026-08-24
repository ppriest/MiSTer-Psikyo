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

This is a rewrite of a verified module, so it is worth confirming first whether `FrameStart`
alone resolves the visible defects. If it does, the line-buffer change is an optimisation
rather than a fix.
