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

## Defect 3: source records replaced mid-render

`spriteram_dbuf` snapshots the live sprite RAM at `frame_start` (a true COPY into the frozen
bank the engine reads — it was a bank ping-pong once, changed after the "a swap is not a
copy" lesson in `docs/LESSONS_LEARNED.md`; the render start is held until the ~4098-cycle
copy completes). The engine reads sprite records across the whole frame, so a pass that
overruns past the next `frame_start` has the next frame's copy land underneath it and draws
two frames' sprites mixed. Independent of the output buffer.

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


## OPEN: sprites sit one scanline below the tilemaps (found 2026-09-01)

Reported on hardware: sprites and tilemaps disagree by one scanline. Present on
build 848 as well as 849, so it dates from the per-scanline renderer itself
(build 847) and was simply invisible under the wrong-tile corruption that build
also had. Ruled out by inspection: the sub-tile ordinal retiming (`44adccc`)
cannot move a sprite, because `sprite_subtile_step` derives sub_x/sub_y from
ix/iy and uses `subtile_ordinal` ONLY for `sub_code`. Timing is ruled out too --
849 has zero failing paths and still shows it.

The two paths get their line number by different means:

| path | how it gets its line | result |
|---|---|---|
| tilemap | `.vcnt(vcnt_next_active)` wired straight in (psikyo_core.sv), latched at `line_start` | row k displayed on line k |
| sprite | line comes from the line buffer's BANK SWAP; the bank rendered in one window is displayed in the NEXT | row k displayed on line k+1 |

`video_timing.sv` fires `line_start` at `hcnt == H_ACTIVE-1`, i.e. at the END of
a visible line, and `sprite_line_buffer` swaps banks on it. So a bank filled
during the window after line_start(j) is not displayed until the window after
line_start(j+1) -- whose visible area is line j+2. With `le_start` sampling
`render_line = vcnt_next_active` about 320 clk after line_start (still within
line j, so vcnt = j), the bank ends up holding row j+1 but being displayed on
line j+2.

Proposed fix: `render_line` needs `vcnt + 2`, not `vcnt + 1`, with
`next_line_visible` adjusted to match and the wrap at V_TOTAL handled. The
whole-frame renderer could not drift this way because the compositor indexed it
directly as `rd_y = vcnt_active`.

CONFIRM THE DIRECTION BEFORE CHANGING IT. The defect was reported as sprites
one line UP, which is the opposite of the analysis above; the screen was being
viewed with 180-degree flip enabled, which inverts the vertical axis and would
invert the apparent direction. Re-check with flip OFF first -- it costs no
build, and getting the sign wrong doubles the error instead of fixing it.

Worth adding to sim/sprite_line_tb when this is fixed: the differential bench
compares which SPRITE line each pixel belongs to, not which SCREEN line it is
displayed on, so it is structurally blind to this defect -- the same shape of
gap as the tile-content aliasing that hid the ordinal truncation.

## REINSTATED: the per-scanline path is now the only path (2026-08-30)

The section below records the 2026-08-29 attempt and its parking. On
2026-08-30 the line renderer was recovered from git history, root-caused,
redesigned, and made the ONLY sprite path; `sprite_render_engine` +
`sprite_frame_buffer` are retired from synthesis (kept in the tree as the
golden reference for the differential testbench). Three distinct defects
were found in the parked version:

1. **Lost `line_start` pulses** (the parked diagnosis, confirmed by
   inspection): the FSM consumed the pulse only in S_IDLE, so one overrun
   ate the next start, finished the old line into the freshly swapped
   bank, and idled a line -- compounding downward exactly as seen on
   hardware. Fixed: `line_tick` hard-resyncs the engine every line;
   rendering aborts (writes stop that cycle), in-flight SDRAM handshakes
   drain during the buffer's 320-cycle clear, and at worst one line loses
   its tail sprites (counted on overlay row 219).
2. **Per-line cost scaled with list length**: every line re-walked the
   display list and re-fetched every 4-word record (~10 cycles per sprite
   per line; busy lists burned most of the 5,472-cycle budget before any
   pixel). Fixed structurally: `sprite_line_list` walks/fetches/prunes
   ONCE per frame in vblank into a compact table (18-bit y-test word +
   64-bit raw record per entry, display-list order preserved); the
   per-line scan is one cycle per candidate.
3. **Sub-tile row overlap under zoom** (found by the differential test,
   never diagnosed on hardware -- and the likely "broken with large
   sprites"): with zoom, adjacent sub-tile rows can overlap by a line
   (row step `zoom_y_t>>1` can be one less than `dst_size_y`), and the
   whole-frame engine draws both with the HIGHER row overwriting.
   The parked engine searched rows bottom-up and rendered the lower row
   on overlap lines -- wrong tile row exactly on large zoomed sprites.
   Fixed: FIND_ROW searches top-down.

Sequencing is MAME-exact end to end: at frame_start the table rebuild
reads the snapshot (get_sprites), then `copy_start` refreshes the snapshot
(m_spriteram->copy) -- capture at vblank, table one buffer-generation old.
Sprites are composed one LINE after rendering, so the sprite palette
snapshot (defect 4) became a live write-through MIRROR of palette entries
0x000-0x1FF -- live palette at scanout, like the tilemaps and the PCB.

Verified by `sim/sprite_line_tb/tb_sprite_line_diff.sv`: the line path
against the retired frame engine, per-pixel over all 224 lines, ten cases
including an 8x8 large sprite, zoom+flip combinations, screen edges,
transparency, 100 random overlapping sprites (depth-order check), an
abort-mid-line resync regression, and off-screen pruning. ALL PASS, with
deliberately different ROM-model latencies on the two sides.

Defects 1/2 (tear, clear overlap) are structurally impossible in a line
buffer; defect 6's latency accounting is preserved by construction. The
frame buffer's ~1.7 Mbit of M10K (about 170 blocks) is freed; the table
costs ~9 back.

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

Unrelated footnote: later the same day a render-engine per-column pipeline
stage (a pure timing change) made transitions look WORSE again on hardware.
That was a separate, new artifact introduced by the pipeline itself, and the
pipeline was reverted the same day; the palette-snapshot fix above stands as
verified (build 20260874).

## Defect 5: game-driven sprites-disable freezes, not blanks -- FIXED (2026-08-29)

The spriteram control word (word 0xFFF) bit 0 is the game's own
sprites-disable. It was latched at frame_start into ctrl_active
(spriteram_dbuf.sv) and gated want_frame in psikyo_core.sv, so no new render
pass started -- but it did NOT gate the compositor's sp_present, so with the
output double-buffered the display bank held the last rendered sprites
indefinitely instead of blanking (MAME blanks sprites the frame the bit is
honored). Identified 2026-08-29 by inspection.

Fixed the same day, with a stronger contract than the planned display-aligned
latch: per the author of MAME's renderer, the global sprite ENABLE is
deliberately **live** -- spriteram_dbuf.sv now exports
`sprites_disable = ctrl_shadow[0]` (the last CPU-written value, not the
frame-latched copy) and psikyo_core.sv gates the compositor's sp_present
with it directly, exactly like the OSD's dbg_render_dis[0] gate. Sprites
blank the moment the game writes the bit. The transparent-pen selects stay
frame-latched (they parameterize the render pass already in flight). See
spriteram_dbuf.sv's closing comment.


## Defect 6: sprites led the tilemaps by a frame -- FIXED

Symptom: magenta fringing beside moving objects in Strikers 1945 (planes and
their shadows), and generally sprites reacting a frame before the tilemaps
they should be locked to. Tilemaps read VRAM live, so any sprite latency
shortfall shows up as sprites running ahead.

psikyo.cpp's memory map is explicit about the reference behaviour:

    map(0x400000, 0x401fff).ram().share("spriteram");
        // Sprites, buffered by two frames (list buffered + fb buffered)

Two independent frames, and this core had neither in full:

| half | reference | what this core did |
|---|---|---|
| list | `screen_vblank` runs `get_sprites()` and only THEN `m_spriteram->copy()`, so a pass renders from the buffer as it stood -- one generation old | snapshot was refreshed at `frame_start` and rendered immediately, so a pass used the CURRENT contents |
| fb | hardware frame buffer, displayed the following frame | output bank swapped the instant rendering finished, about 61% down the same frame it was drawn in |

Fixing only the list half is worth about 0.4 frame and reads as no change on
hardware -- the fb half carries most of it. Both were needed:

- `spriteram_dbuf`'s copy is triggered when the render pass finishes with the
  snapshot (`copy_start`), not at `frame_start`. Costs no memory; a second
  snapshot bank would be 64Kbit and this design has no M10K spare.
- The output buffer swaps at the frame boundary (the `status[43]` policy,
  now the default), so a rendered pass is displayed over the following whole
  frame.

Moving the copy after the render also leaves the snapshot unprimed at
power-on, which rendered uninitialised contents as briefly corrupted sprites.
The first `frame_start` after reset now performs a copy instead of a render,
and rendering waits for a completed copy.

Note the frame-boundary swap is the same policy that previously stopped the
core booting (see "Defect 1"). It boots with the render start no longer gated
behind a 4096-cycle copy, but it remains selectable on `status[43]` so a
regression can be isolated without a rebuild.
