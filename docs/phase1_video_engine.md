# Phase 1 Video Engine Design — Tilemaps + Zoom Sprites (PS2001B/PS3103/PS3204/PS3305)

This is the real engineering content of the project (see docs/ROADMAP.md) — no existing FPGA
implementation of this hardware exists anywhere. Everything below is derived directly from
`psikyo_v.cpp`, with the non-obvious bit arithmetic worked through and numerically verified
rather than taken at face value from the C++ source's shape (see "Tilemap addressing").

## Screen timing (recap, both Phase 1 boards identical)

320×224 visible, htotal 456, vtotal 262, pixel clock ≈7.159 MHz (`14.31818_MHz_XTAL/2`),
~59.923 Hz, 38 lines vblank. See docs/phase1_memory_map.md for clocks.

## Tilemap addressing

`tile_scan<Layer>` (psikyo_v.cpp:88-98) computes a VRAM word index from `(col, row)`, but its
result is always consumed through `get_tile_info` as `tile_index & 0xFFF` (psikyo_v.cpp:81) —
i.e. only the low 12 bits ever matter. Working through each case's bit terms against that mask
(verified numerically, see the check below) shows every "extra" term in the C++ lands entirely
in bits 12+ and is discarded:

| Size code (vreg bits 6-7) | Formula after masking | Grid | Pixel size |
|---|---|---|---|
| 0 | `col[5:0] \| row[5:0]<<6` | 64×64 tiles | 1024×1024 |
| 1 | `col[6:0] \| row[4:0]<<7` | 128×32 tiles | 2048×512 |
| 2 | `col[7:0] \| row[3:0]<<8` | 256×16 tiles | 4096×256 |
| 3 (default) | `col[4:0] \| row[6:0]<<5` | 32×128 tiles | 512×2048 |

**All four are just plain row-major addressing**, `index = col + row * width`, for `width` =
64/128/256/32 respectively — confirmed by brute-force checking every `(col,row)` pair in each
mode's grid maps to a distinct index in `0..4095` matching `col + row*width` exactly (no
aliasing, full bijection onto the 4096-word VRAM). This is a much simpler result than the
bit-interleave the raw C++ suggests, and a huge simplification for the RTL: **the tilemap
address generator is just a counter/adder per mode, not a bit-shuffle network.**

Practical RTL implication: a small mode-select mux picks `width ∈ {64,128,256,32}` (equivalently
a 2-bit shift amount for the multiply-by-width, since all four widths are powers of two:
`row << {6,7,8,5}[mode]`), then `index = col + (row << shift)`. Trivial in hardware.

## Tile cell format (VRAM, both layers)

16-bit cell, big-endian semantics (psikyo_v.cpp:73-75):

| Bits | Meaning |
|---|---|
| 15-13 | Color code (0-7) — palette bank offset is `code*16 + layer*0x40*16`-ish (exact gfxdecode color-base arithmetic to pin down when the palette/gfxdecode RTL is designed, not blocking here) |
| 12-0 | Tile code within the current bank |

Actual gfx ROM tile number = `(cell & 0x1FFF) + 0x2000 * bank`, where `bank` (0-3) is set via
`switch_bgbanks()` — for Phase 1's sngkace/gunbird boards, layer 0's bank is fixed at 0 and
layer 1's fixed at 1 (`VIDEO_START_MEMBER(psikyo_state,sngkace)`, psikyo_v.cpp:131-137) *except*
gunbird/btlkroad additionally support live bank switching via vreg control-word bit 10
(`m_ka302c_banking` flag, layer_ctrl bit 10 → bank 0-3) — confirmed this is real per-board
behavior, not a simplification: gunbird_map's board sets `m_ka302c_banking = true` (need to
re-verify exact set-site when implementing; flagged here so it isn't missed).

Tile size 16×16, 4bpp (`Tiles: 16x16x4` per the driver's header comment).

## Row-scroll application

Both layers, independently. Vreg layer-control bits 8-9 select the mode (see
docs/phase1_memory_map.md for the full control-word bit table):

- **No row-scroll** (bit 8 clear): single X-scroll value = `layer_ctrl_base_x`
  (vreg `0x406`/`0x40E`) for the whole layer.
- **Row-scroll active** (bit 8 set): per-screen-line (bit 9 clear) or per-*tile-row*
  (bit 9 set, i.e. one value shared across 16 consecutive screen lines) X-scroll, read from the
  layer's row-scroll table (vreg `0x000-0x1FF` for layer 0, `0x200-0x3FF` for layer 1) at index
  `screen_line >> (bit9 ? 4 : 0)`, **added to** the base X-scroll value, not replacing it
  (`scrollx[layer] + x0`, psikyo_v.cpp:506).
- Y-scroll is a single value per layer always (no row/line Y-scroll in this hardware) — vreg
  `0x402`/`0x40A`.
- The table lookup index used to *place* the computed scroll value into MAME's per-row scroll
  array is `(screen_line + scrolly[layer]) & 0x7FF` (psikyo_v.cpp:505) — i.e. the row-scroll
  table is logically anchored to the *scrolled* Y position, not the raw screen line. Worth
  getting this exactly right in RTL: it means the row-scroll fetch address depends on both the
  current raster line **and** the layer's Y-scroll register, not just the raster line alone.

RTL implication: the tilemap engine needs to prefetch, once per screen line (or once per 16
lines in per-tile mode), one 16-bit value from the vregs row-scroll table before that line's
pixel generation starts — a small lookahead, not a full line of latency.

## Sprite format (spriteram attribute table, `0x400000-0x401 7FF`)

768 entries × 8 bytes (psikyo_v.cpp:185-284, `get_sprites()`). Per entry:

```
+0x0 (word): Y position/size/zoom       fedc ---- ---- ----   zoom Y (4 bits, raw 0-15)
                                         ---- ba9- ---- ----   tile count Y - 1 (3 bits, 0-7 => 1-8 tiles)
                                         ---- ---8 7654 3210   Y position (9 bits)
+0x2 (word): X position/size/zoom       same layout as Y, for X
+0x4 (word): color/flags/code-hi        f--- ---- ---- ----   flip Y
                                         -e-- ---- ---- ----   flip X
                                         --d- ---- ---- ----   ? (used, meaning unknown)
                                         ---c ba98 ---- ----   color (5 bits, bits 12-8)
                                         ---- ---- 76-- ----   priority (2 bits) -- see below
                                         ---- ---- ---- ---0   code, high bit
+0x6 (word): code low bits              full 17-bit raw code = (bit0 of +0x4) << 16 | (+0x6)
```

**Color field is 5 bits (`attr[12:8]`), not 4** — the ASCII-art bit comment above (transcribed accurately from psikyo_v.cpp) marks 5 positions (`c b a 9 8`), but an earlier pass through this doc mislabeled it "(4 bits)" and the first RTL draft used `attr[11:8]`, dropping bit 12. Confirmed the width by tracing where the C++'s `color = attr>>8` value (all 8 upper bits, unmasked) actually gets used: `gfx_element::prio_zoom_transmask` computes the real palette base as `colorbase() + granularity()*(color % colors())` (`drawgfx.cpp:1392`), and the sprite `GFXDECODE_ENTRY` declares 32 color groups (`0x20`) — so only `color % 32` (the low 5 bits of `attr>>8`, i.e. `attr[12:8]`) ever matters; bit 13 (`?used`) is excluded from color and genuinely unused as far as this trace goes.

**Position sign convention — X and Y are genuinely different, not the same field twice.** Easy
to get subtly wrong by assuming symmetry; re-verified directly against psikyo_v.cpp:214-233
line by line rather than trusted from an earlier pass over this file:

- **X**: raw 9-bit field masked to `0-511` (`x & 0x1FF`), then **conditionally** `-= 0x200` only
  if `x >= 0x180` (384). Asymmetric range: `0-383` positive, `384-511` reinterpreted as
  `-128..-1`. Do not implement this as a sign-bit check on bit 8 — that flips at 256, not 384,
  and would be wrong.
- **Y**: `(y & 0xFF) - (y & 0x100)` — this *is* plain 9-bit two's-complement sign extension
  (flips at bit 8, symmetric-ish range `-256..255`), unlike X.

Both are computed from the *raw, unmasked* 16-bit word — the zoom/size fields living in the
upper 7 bits (`zoom` bits 15-12, tile-count bits 11-9) are extracted from the word *before* this
masking, not after.

Zoom: raw 4-bit field `0-15` (0 = full size). Effective scale = `(32 - raw) / 32`, i.e. raw 0 →
100%, raw 15 → 17/32 ≈ 53% (matches the driver's "shrinks to ~50%" comment). Both X and Y zoom
independently.

### The actual per-tile scaling algorithm

The design doc originally described this qualitatively ("nearest-neighbor, no bilinear") without
having traced the exact formula. Found it: everything funnels through
`gfx_element::drawgfxzoom_core` (`src/emu/drawgfxt.ipp:738`), which is worth recording precisely
since a hand-wavy "roughly nearest-neighbor" description isn't enough to build pixel-exact RTL
from:

```
dstwidth  = (scale * 16 + 0x8000) >> 16      // scale = zoom_transformed << 11, tile is 16x16
dx        = (16 << 16) / dstwidth             // 16.16 fixed-point source-step per dest pixel
// then for each dest column: src_col = (accum >> 16); accum += dx  (accum starts at 0)
```

Working through this for `zoom_transformed` (the `32 - raw` value, range 17-32) against the tile's
fixed 16px width/height reduces to something much simpler than the general formula suggests:

- **`dstwidth = 16 - (raw >> 1)`** — verified by expanding the `(scale*16+0x8000)>>16` formula
  algebraically for `scale = zoom_transformed << 11`: `dstwidth = (zoom_transformed + 1) >> 1`
  exactly, and substituting `zoom_transformed = 32 - raw` gives `(33 - raw) >> 1 = 16 -
  (raw>>1)`(pattern is `raw>>1`, e.g., raw=0,1→16; raw=2,3→15; ...; raw=14,15→9) — a plain
  subtract-and-shift, no multiply or divide needed in hardware at all for this part.
- **`dx`** doesn't reduce to anything similarly clean (it's a real `1048576/dstwidth`), but since
  `dstwidth` only ever takes 8 distinct values (9-16, each hit by two adjacent `raw` values),
  it's exactly representable as a small 16-entry lookup table (indexed directly by the 4-bit raw
  zoom value, one table shared by X and Y since both use the same 16px tile dimension), computed
  once and verified against Python's exact integer arithmetic rather than re-derived by hand in
  RTL:

  | raw | 0,1 | 2,3 | 4,5 | 6,7 | 8,9 | 10,11 | 12,13 | 14,15 |
  |---|---|---|---|---|---|---|---|---|
  | dstwidth | 16 | 15 | 14 | 13 | 12 | 11 | 10 | 9 |
  | dx (16.16 hex) | 0x10000 | 0x11111 | 0x12492 | 0x13b13 | 0x15555 | 0x1745D | 0x19999 | 0x1C71C |

- This is a genuinely important detail for adjacent-tile seam behavior: the *step* between
  adjacent sub-tile origins (`zoom_transformed/2` from the position math, i.e. `(32-raw)>>1`
  truncating) and the *rendered width* of each individual sub-tile (`dstwidth`, rounding instead
  of truncating) are **not the same value** whenever `raw` is odd — the rendered tile is one
  pixel wider than the step, so adjacent shrunk sub-tiles deliberately overlap by one pixel
  rather than leaving a gap. Worth being deliberate about reproducing this rather than
  "simplifying" it away, since it's presumably there to avoid visible seams on shrunk sprites.
- Source pixel selection is confirmed nearest-neighbor (a fixed-point accumulator incrementing by
  `dx`/`dy`, `>>16` to get the integer source index each step) — no bilinear filtering anywhere
  in this pipeline.
- Flip reverses the accumulator's start point and direction (`drawgfxt.ipp:794-805`): start at
  `(dst_size-1)*d + 0` and step by `-d` instead of starting at 0 and stepping by `+d`.
- **The accumulator collapses to a closed form, no running state needed**: since `dx` is constant
  across one sub-tile row, the accumulator value before destination column `col` (0-indexed) is
  just `col*dx` (no-flip) or `(dst_size-1-col)*dx` (flip) — an arithmetic progression, not
  genuinely dependent on the previous column's value. So `src_index = (effective_col * dx) >> 16`
  can be computed directly per destination column without maintaining accumulator state across
  cycles, which is what `sprite_zoom_src_index.sv` does. Verified in Python across the full valid
  domain (all 16 raw values x both flip directions x every valid `col` for that raw's `dst_size`)
  that `src_index` always lands in 0-15 as expected (a source pixel index into one already-decoded
  16-pixel tile row) — never overflows the tile despite the `col*dx` product needing ~21 bits
  before the `>>16`.

**Code → gfx ROM tile number is indirected through a ROM lookup table** (`spritelut` region,
loaded from its own ROM), not used directly. This is a real extra pipeline stage the RTL sprite
engine needs: raw 17-bit code → LUT read → actual gfx ROM tile address. The LUT lookup happens
**per 16×16 sub-tile**, not once per logical sprite (see next section) — the raw code
increments once per sub-tile, and each incremented value is independently looked up.

**LUT ROM format** (`ROM_REGION16_LE("spritelut", 0x040000)`, confirmed identical across
sngkace/gunbird/btlkroad): 256 KB, 16-bit little-endian entries → exactly `0x20000` = 131072
entries, i.e. `2^17`. The pre-LUT `code` field is exactly 17 bits (`{word_attr[0],
word_code_lo}`, max `0x1FFFF` = 131071) — so the hardware's `code & (lutlen-1)` masking is a
**no-op for all three Phase 1 games** (the mask is all-ones at this exact ROM size). Still worth
implementing the AND explicitly rather than assuming it away, in case a later phase's game uses a
differently-sized LUT ROM. The looked-up **16-bit** value is used completely unmodified as the
real gfx-ROM tile index (`draw_sprites()` passes it straight to `prio_zoom_transmask`/
`prio_transmask` as the tile code) — no further shift/offset/bank logic downstream, confirmed by
tracing every use of `sprite_ptr->code` in `psikyo_v.cpp`.

## Multi-tile sprite composition (the actual zoom algorithm)

A logical sprite is `nx × ny` tiles (1-8 each way, up to 64 total 16×16 tiles). Critically, the
hardware/MAME model does **not** zoom-scale one composite bitmap — it zoom-blits each 16×16
sub-tile independently, at a zoom-scaled offset position, all sharing the sprite's one zoom
factor (psikyo_v.cpp:249-283):

- Per-tile step size: `zoomx_effective / 2` pixels (where `zoomx_effective` is the post-`32-raw`
  transform, so effective step at 100% zoom = 32/2 = 16px, matching the un-zoomed 16px tile
  pitch exactly; at max shrink, step ≈ 17/2 ≈ 8.5px, i.e. sub-tiles overlap/compress together).
- Loop order: `dy` outer, `dx` inner — row-major, sub-tile code increments once per inner-loop
  iteration (i.e. left-to-right along a tile row, matching `flipx`'s direction, then down to the
  next row).
- Each sub-tile is blitted with the *same* per-sprite zoom factor via what MAME calls
  `prio_zoom_transmask` — i.e. every sub-tile individually goes through the same
  fetch→zoom-scale→blend pipeline stage in hardware; there's no separate "whole sprite" scaling
  step.

**This is good news for the RTL design**: it means the sprite engine can be built as a per-tile
pipeline (fetch one 16×16 tile, zoom-scale it, blend it into a destination buffer at its computed
position) iterated up to 64 times per sprite, rather than needing an arbitrary-size 2D scaling
engine. The zoom scaling itself (16×16 source → variable-size destination) is the one genuinely
hard, novel piece of hardware here — no existing MiSTer core's zoom-sprite implementation can be
directly reused (CAVE's is conceptually the closest analog per docs/ROADMAP.md, but Chisel/
different toolchain, so it's design inspiration only). (Note: that "destination buffer" is a
full frame buffer, not a scanline line buffer like the tilemap engine uses — see "Sprite frame
renderer: architecture" below for why.)

## Sprite double-buffering

Hardware double-buffers the whole 8 KB spriteram, swept on vblank's *rising* edge
(`screen_vblank()`, psikyo_v.cpp:667-675; also flagged in docs/phase1_memory_map.md). RTL needs
two independently-addressable 8 KB BRAM banks with a bank-select flip-flop toggled once per
frame, not a single buffer — the CPU can be actively writing next frame's list into one bank
while the sprite engine is still reading the other bank's contents for the frame currently being
scanned out.

## Sprite frame renderer: architecture

**This is a real design decision, not something the C++ dictates directly** — worth stating
explicitly since it's a deliberate departure from the tilemap engine's approach, not an
oversight. Recording the reasoning so it isn't re-litigated later.

MAME's `draw_sprites()` blits sprites into a full-frame `bitmap`/priority-bitmap pair that
already holds the complete tilemap raster for the whole frame (tilemaps are drawn first, in
their entirety, before any sprite is drawn). The tilemap engine here works the opposite way —
`tilemap_line_engine` generates each layer's pixels **just-in-time**, one scanline ahead of
scanout, with no full-frame storage at all. Two questions decide whether sprites can work the
same just-in-time way:

1. **Inter-sprite overlap.** Where two sprites' pixels land on the same screen position, the
   *later* entry in the display list wins (drawn on top, in list order — plain sequential
   overwrite, like MAME's blit loop). This is fine for a real-time approach too, in principle:
   process the display list once for a given scanline in list order, and let later sprites
   overwrite earlier ones in that scanline's line buffer. **But** a sprite can be up to 128px
   tall (8 tiles × 16px) and cover multiple scanlines, and the display list can hold up to 1023
   entries — so "which sprites touch scanline N" is not a cheap lookup, it requires walking the
   *entire* display list for every single scanline (worst case 1023 entries × 224 lines ≈ 229K
   entry-checks) to correctly preserve list-order overwrite semantics per line, since a sprite's
   list position (draw priority) is independent of its Y position, so entries can't just be
   sorted by Y up front and still preserve tie-breaking against sprites that don't overlap in Y.
2. **Time budget.** One scanline is only `htotal` = 456 pixel-clocks (≈ 63.7 cycles/MHz of
   internal clock beyond the 7.16MHz pixel clock, depending on the render engine's actual clock).
   Walking even a fraction of a 1023-entry display list, per sub-tile (up to 64 sub-tiles/sprite,
   each needing a spritelut ROM read + gfx ROM read + a 16×16 zoom-blit), inside one scanline's
   budget is not realistic at any plausible on-FPGA clock — this is fundamentally a "render ahead
   of time" problem, not a "keep up with the beam" one.

**Decision: sprites render into a full 320×224 frame buffer, once per frame, decoupled from
pixel-clock timing** (a free-running render engine clocked by the system clock, not the pixel
clock) — this is the standard approach for zoom-sprite MiSTer cores of this class (matches
CAVE_MiSTer's structure per `docs/ROADMAP.md`'s survey, though not its Chisel implementation).
Concretely:

- **Two full frame buffers** (ping-pong, same `fb_render_sel` toggle idea as the spriteram
  double-buffer, switched together since they're driven by the same vblank event): one being
  rendered into for the *next* frame while the *other* is read out during the *current* frame's
  scanout.
- Per pixel stored: sprite's palette-lookup fields (color/pixel-index, not yet resolved through
  the palette RAM — palette lookup stays at composite time, matching every other layer) + a
  1-bit "sprite pixel present" flag + the sprite's raw 2-bit priority field (the `primask`
  gate is derived from it at composite time — see "Priority / compositing" below). Whatever the sprite that
  currently owns that pixel is, later sprites overwrite it during the render pass exactly like
  MAME's sequential blit — **this fully resolves inter-sprite overlap by the time rendering
  finishes**, before scanout ever reads the buffer.
- Sizing: on-chip BRAM is large enough for this on the DE10-nano's Cyclone V (5CSEBA6) — 320×224
  = 71,680 pixels; even a generous per-pixel width (color index + present flag + primask) is
  comfortably inside the ~5.6Mbit of embedded M10K memory, so no SDRAM frame buffer is needed
  purely for sprites (SDRAM is still needed for the tile/sprite/sound ROMs themselves).
- **The final tilemap-vs-sprite priority decision is still resolved live, at scanout, not during
  sprite rendering** — this is the key point that makes decoupled rendering correct despite
  sprites being rendered "blind" to what the tilemaps will eventually draw: the
  `primask[tilemap_priority]` gate (bit-indexed, see below) only depends on the *current pixel's* live tilemap-layer priority
  value and the *already-resolved* sprite `primask` at that pixel, both available simultaneously
  when the compositor combines `tilemap_line_engine`'s live output with the pre-rendered sprite
  frame buffer's stored output for the scanline currently being scanned out. Sprite rendering
  never needs to know what the tilemaps drew.

**Open risk, not yet resolved**: whether the render engine can actually finish worst-case-sized
display lists (1023 entries, theoretically up to 65536 sub-tile blits if every entry pointed at
an 8×8-tile sprite) within one frame period at a realistic clock. Real games are extremely
unlikely to hit that theoretical worst case, but this hasn't been budgeted against actual game
sprite counts yet (no frame-by-frame sprite-count trace pulled from MAME so far) — flagging this
now rather than discovering it late; may need a "spend at most N cycles per sub-tile, drop
excess" bound or a faster render clock once real numbers are available. Tracked in
`docs/ROADMAP.md`'s open items.

## Priority / compositing

Draw order (psikyo_v.cpp:522-540): layer 0, then layer 1, then sprites — each tilemap layer's
opaque pixels write a fixed category value into a shared priority bitmap (layer 0 → 1, layer 1
→ 2) as it's drawn, and sprites are gated against that priority bitmap by a `primask` derived
from the sprite's 2-bit priority field via a fixed table `{0, 0xFC, 0xFF, 0xFF}`
(psikyo_v.cpp:189).

**The mask is BIT-INDEXED by the destination priority value — MAME's pdrawgfx convention: the
sprite pixel is BLOCKED when `primask[dest_priority]` is set** (`dest_priority` here only ever
holds 0 = nothing drawn, 1 = layer 0 on top, 2 = layer 1 on top). An earlier pass through this
section worked the table through as a value-AND (pixel drawn iff
`(dest_priority & primask) == 0`) and concluded the hardware had only two sprite tiers; that
reading was WRONG, and the value-AND implementation built from it let priority-1 sprites beat
tilemap 1 unconditionally (samuraia's cloud sprites over the foreground layer — root-caused on
real hardware via the JTAG spriteram probe, fixed BIT-INDEXED in commit `284cad6`, verified on
hardware 2026-08-29). Under the correct bit-indexed reading, with the RTL's table
`{0, 0xFC, 0xFE, 0xFF}` (entry 2 corrected from MAME's published `0xFF` to `0xFE`, direct from
the author of MAME's Psikyo renderer reviewing live gameplay — commit `0c63a5b`):

| Sprite priority field | primask | bits 0 / 1 / 2 (backdrop / layer 0 / layer 1) | Net effect |
|---|---|---|---|
| 0 | `0x00` | none set | above everything |
| 1 | `0xFC` | bits 0-1 clear, bit 2 set | above layer 0, below layer 1 |
| 2 | `0xFE` | bit 0 clear, bits 1-2 set | below both layers, visible over backdrop |
| 3 | `0xFF` | all set | never visible |

So the hardware has real intermediate tiers, not the two-tier collapse the value-AND reading
suggested. The live source of truth is `compositor.sv` (its testbench's cases 6-9 fail against
a value-AND implementation); start any future work on this table from that source, not from
this section's history.

## Compositor: backdrop, transparent-pen, and palette lookup

Traced `screen_update()` directly (not re-derived from the earlier write-up above) for the parts
the compositor needs that aren't covered by the priority-mask table: how each layer decides
per-pixel opacity, and what shows through when nothing draws at a pixel at all.

**Per-tilemap-layer opacity**, from `layer_ctrl[N]` (both layers, same bit encoding, per
`docs/phase1_memory_map.md`'s table):

```
transparent_pen = (layer_ctrl[N] & 8) ? 0 : 15
layer_draws_here = layer_enabled && (opaque_mode || pixel != transparent_pen)
```

`opaque_mode` is bit 1 (`TILEMAP_DRAW_OPAQUE` — draws every pixel regardless of pen, "used in
Gunbird's attract mode" per the memory-map doc). `layer_enabled` is bit 0, applied via MAME's
`tilemap->enable()` rather than a direct guard around the `draw()` call itself — functionally
equivalent to ANDing it into the opacity decision, which is how this folds into RTL: an entirely
disabled layer just never draws, same as if every pixel were its transparent pen.

**Sprites need no equivalent per-pixel check here** — `sprite_render_engine` already applied
`trans_pen0`/`trans_pen15` before ever writing to the frame buffer, so `sprite_frame_buffer`'s
`rd_present` already means "this sprite pixel is opaque," full stop.

**Backdrop (nothing drawn anywhere)** — genuinely surprising once traced, worth recording
precisely rather than assuming symmetry between the two layers:

```c
int layers_ctrl = -1;   // hardcoded, never actually written elsewhere
if (layers_ctrl & 1)
    bgpen = palette[(layer_ctrl[0] & 8) ? 0x800 : 0x80f];
else if (layers_ctrl & 2)
    bgpen = palette[(layer_ctrl[1] & 8) ? 0xc00 : 0xc0f];
else
    bgpen = palette.black_pen();
```

`layers_ctrl` is a local hardcoded to `-1` (MAME's own source flags this with a `// TODO: is
this correct?` / Coverity-suppression comment) — so `layers_ctrl & 1` is **always true**, and
the `else if`/`else` branches are **dead code**, never reached in the current driver. The
backdrop is therefore **always** derived from **layer 0's** transparent-pen-select bit alone
(`0x800` = layer 0's colorbase + pen 0, or `0x80f` = pen 15), regardless of which layer is
actually enabled or what layer 1's own control bits say. This looks like an unfinished
reverse-engineering effort on MAME's part (the intent was probably "pick whichever layer is
enabled, or black if neither"), but per this project's standing rule — MAME's actual behavior is
the accuracy target, not a guess at more-correct hardware — the original RTL reproduced this
exact quirk: `bgpen = palette[(layer0_ctrl & 8) ? 0x800 : 0x80f]`, unconditionally.

**Update, live on hardware 2026-08-29:** the built `compositor.sv` now deliberately diverges
from that MAME quirk — the backdrop is a FIXED pen 0 (`palette[0x800]`), never selected by
layer 0's transparent-pen bit, per the MAME renderer author's direction: the pen-15 branch put
a magenta clear on screen whenever that bit chose pen 15. The live source is `compositor.sv`'s
own backdrop comment.

**Palette addressing**: `xRGB_555`, 4096 entries, 8KB (`docs/phase1_memory_map.md`). Combining
with `tile_cell_decode`'s `color` output (already includes layer 1's `+64` offset) and the
GFXDECODE colorbase/granularity values (`gfx_psikyo`, psikyo.cpp: sprites colorbase `0x000`,
tiles colorbase `0x800`, both granularity 16 since both are 4bpp):

```
tilemap palette index = 0x800 + color*16 + pixel     (color already includes +64 for layer 1)
sprite  palette index = 0       + color*16 + pixel     (color is the raw 5-bit sprite color field)
```

**Draw-order resolution** (layer 0 → layer 1 → sprite, each overwriting where it draws,
`primask` gating sprites per the table above): implemented as a plain priority mux rather than
an actual bitmap, since the compositor only ever needs *this pixel's* final winner, not a
persisted priority buffer — `tilemap_line_engine` already regenerates layer pixels live every
frame, so there's nothing to accumulate across pixels the way MAME's `bitmap`/`priority` buffers
do:

```
priority_val = l1_draws ? 2 : (l0_draws ? 1 : 0)
sprite_wins  = sp_present && !primask[sp_priority][priority_val]   // BIT-indexed, never value-ANDed
winner       = sprite_wins ? sprite : (l1_draws ? layer1 : (l0_draws ? layer0 : backdrop))
```

**Output shape of the built compositor (redesigned 2026-08-29):** `compositor.sv` is a pure
combinational priority resolver that emits TWO parallel palette lookups per pixel plus a
select — `pal_addr` (the tilemap/backdrop entry, into the live palette RAM), `pal_s_addr`
(the sprite entry, into the 512-entry sprite-palette SNAPSHOT copied from the live palette at
`frame_start`, so sprite pixels — themselves rendered a frame earlier — and sprite colors
change scene together), and `sprite_sel`. The final registered RGB mux applying `sprite_sel`
to the two BRAMs' outputs one cycle later lives in `rtl/psikyo_core.sv`, not in the
compositor (whose module comment explains why registering `rgb` internally would silently
double the pipeline latency). Tilemaps render live and keep the live palette.

## RTL module breakdown (the original proposal — all three pieces are long since built; see the as-built notes above and below)

1. **Tilemap engine** (×2 instances, one per layer) — address generator (trivial per above) +
   VRAM read + gfx ROM tile fetch + row-scroll prefetch + horizontal line-buffer shift register.
   The simplest of the three major pieces; good first implementation target.
2. **Sprite engine** — double-buffered spriteram, display-list walk, per-sub-tile zoom-blit
   pipeline, spritelut ROM indirection. The hard, novel piece.
3. **Compositor** — per-pixel priority resolution (bit-indexed `primask` gate) +
   transparent-pen handling, resolving to two parallel palette lookups (live palette for
   tilemap/backdrop, snapshot palette for sprites) + a sprite select; the registered RGB mux
   lives one level up in `psikyo_core.sv`.

Implementation order: tilemap engine first (self-contained, independently testable against
known VRAM content and expected tile-fetch address sequences), then sprite engine, then
compositor tying both together — matches the "prove the simpler piece first" approach used for
the CPU spike in Phase 0.

## Tilemap scanline sequencer (`tilemap_line_engine`)

The four modules built so far (`tilemap_coord`, `tilemap_addrgen`, `tile_cell_decode`,
`tile_row_decode`) are pure combinational address/decode math. This module is the first
sequential piece — it drives them against real per-cycle timing and memory latency, one instance
per layer.

**Interface contract, stated explicitly since it's a real design decision, not something derived
from the C++ source:**

- `hcnt`/`vcnt` come from a not-yet-built top-level timing generator, on the convention `hcnt` =
  0-319 active / up to 455 total, `vcnt` = 0-223 active / up to 261 total (matches
  `set_raw(...,456,0,320,262,0,224)`, docs/phase1_memory_map.md). This module only consumes
  them; it doesn't generate sync.
- VRAM and the row-scroll table are on-chip BRAM (4096 words / 256 words respectively — small
  enough that off-chip storage is never worth it) — **1-cycle synchronous read latency**
  assumed.
- The gfx ROM ("tiles" region) is the one interface where real latency is genuinely unknown
  this early (depends on the eventual SDRAM controller / cache design) — modeled as a
  **request/valid handshake** (`gfxrom_req`, `gfxrom_valid`) rather than a fixed cycle count, so
  this module doesn't need to be rewritten once that decision is made elsewhere.
- **Timing requirement this module places on that gfx ROM interface**: one tile fetch (VRAM
  read → cell decode → gfx ROM row read → row decode) must complete within 16 pixel-clocks, to
  keep up with double-buffered prefetch (below). This is a real constraint on whatever backs the
  gfx ROM later, not just an implementation detail — flagging it here so it isn't lost. The
  module does **not** silently produce wrong pixels if this is violated: a sticky
  `fetch_overrun` output flags it, checked by the testbench, so a future integration that
  can't meet the budget fails loudly instead of glitching quietly.

**Pipeline**: double-buffered (ping-pong) tile prefetch. While shifting out the current buffer's
pixels one per pixel-clock, the *other* buffer is fetched for the next tile. Two things this has
to get right that are easy to get subtly wrong:

1. **Sub-tile scroll alignment.** The line's starting effective X position generally isn't
   16-pixel-aligned (`fine_x` from `tilemap_coord` is nonzero). Rather than threading a running
   "current pixel offset within tile" through the whole pipeline, the fetch address is always
   rounded down to the enclosing tile boundary (`eff_x - fine_x`, then +16 per subsequent
   fetch — plain tile-boundary stepping from then on), and each buffer separately records its
   own *display* start-offset and pixel-count: the first tile of a line displays
   `(16 - fine_x)` pixels starting at index `fine_x` into its decoded row; every tile after that
   displays all 16 pixels from index 0. This only needs figuring out once per line, not
   per-pixel.
2. **Row-scroll table fetch index.** Confirmed from `psikyo_v.cpp:500-507`: the table is indexed
   by the *raw* screen scanline (`vcnt`, or `vcnt >> 4` in per-tile mode) — **not** by the
   Y-scrolled line. (MAME's own code adds `scrolly` when *storing into* its internal per-row
   scroll array, which is a detail of how MAME's abstract tilemap object maps rows to scanlines
   internally, not part of the table-fetch address itself. Worth stating explicitly since the
   `(i+scrolly)&0x7FF` term in the source could easily be misread as "the fetch address," which
   it isn't.) `tile_row`/`fine_y` themselves come from `eff_y = base_y_scroll + vcnt` through
   `tilemap_coord`, same as any other layer position — Y has no row/line-granularity scrolling at
   all, only X does.

Per-line sequence: on a `line_start` pulse (during the horizontal blanking interval, well ahead
of `hcnt` reaching 0 — ~136 pixel-clocks of headroom per docs/phase1_memory_map.md's timing),
fetch the row-scroll table entry, compute `eff_y`/`eff_x_start`, then prefetch the line's first
one or two tiles before active display begins. From there, every 16 pixel-clocks (or fewer, for
the line's first partial tile) triggers a buffer swap and the next fetch.

## Sprite render engine: pipeline design (`sprite_render_engine`)

Every combinational piece needed by this module already exists and is independently verified —
this section is about how they chain together, plus a few interface details/gotchas that only
show up at integration time and wouldn't be visible from any single module's own spec.

**Component inventory** (all in `rtl/video/`, all already built+verified except the top-level
FSM itself):

| Stage | Module | Role |
|---|---|---|
| 1 | `sprite_display_list_walker` | emits sprite indices (0-767), flow-controlled via `advance` |
| 2 | `sprite_record_fetch` | fetches the 4-word attribute record for one sprite index |
| 3 | `sprite_record_decode` | (combinational) record → position/zoom/flip/color/code fields |
| 4 | `sprite_pos_transform` | (combinational) offset-correction + zoom transform |
| 5 | `sprite_zoom_lut` | (combinational) raw zoom → `dst_size`/`dx` — needed **twice** (X and Y independently zoom) |
| 6 | `sprite_subtile_step` | (combinational) per-sub-tile position + LUT-index code |
| 7 | *(new, trivial, inline — no separate module)* | spritelut ROM address = `sub_code` directly (§ "LUT ROM format" above — masking is a no-op for Phase 1's ROM size, still applied) |
| 8 | `sprite_zoom_src_index` | (combinational) per-destination-pixel source index — needed **twice** (X and Y independently), see the flip gotcha below |
| 9 | *(new, trivial, inline)* | gfx ROM row address = `{tile_code, src_row, 3'b000}` (byte address, 23 bits — sprite gfx ROMs run up to 0x700000-0x800000, one bit wider than the tilemap engine's 22-bit `gfxrom_addr`) |
| 10 | `tile_row_decode` | (combinational, **reused from the tilemap engine unmodified** — its header already documents it as shared) — decodes one fetched row into 16 pixel values |

**Gotcha: flip must not be applied twice.** `tile_row_decode` has its own `flip_x` port (built
for the tilemap engine's simpler non-zoomed case, where flip is just "reverse the 16 pixels").
`sprite_zoom_src_index` *also* fully accounts for flip internally — per `drawgfxzoom_core`, flip
changes which *source* index a given *destination* column reads from (`(dst_size-1-col)*dx`
instead of `col*dx`), reading directly from the tile's natural, unflipped pixel order. Since
`sprite_zoom_src_index`'s output already IS the correct (flip-aware) source index into the
natural row, **`tile_row_decode` must always be instantiated with `flip_x` tied to `1'b0`** in
this pipeline — passing the sprite's real `flip_x` there too would flip twice and cancel out,
producing unflipped output for flipped sprites. (Y-axis flip has no equivalent second module to
confuse it with: `sprite_zoom_src_index`'s Y instance, fed `flip_y`, directly produces the
correct source *row* index for the gfx ROM address — there's nothing downstream that could
double-apply it.)

**Transparent pen handling** (re-verified against current `draw_sprites()` source, not
previously documented): the spriteram control word's bits 2/3 independently make pixel value 0
and/or pixel value 15 transparent — `transmask = (ctrl&4 ? 1<<0 : 0) | (ctrl&8 ? 1<<15 : 0)`.
Both, either, or neither can be transparent depending on the live control word — this is a
per-frame runtime setting, not fixed at synthesis time, so the render engine needs `trans_pen0`/
`trans_pen15` as inputs (the caller reads the control word once per frame and derives them, same
"caller's responsibility, not this module's" split already used for the sprites-disable bit).
Per pixel: `opaque = !((pixel==4'd0 && trans_pen0) || (pixel==4'd15 && trans_pen15))`.

**Screen-space clipping.** A sub-tile's per-pixel screen position (`sub_x + dst_col`,
`sub_y + dst_row`) can land outside the visible 320×224 area — `sub_x`/`sub_y` alone range up to
[-128,495]/[-256,367] (per `sprite_subtile_step`'s header), and `dst_col`/`dst_row` add up to 15
more. Out-of-range pixels are simply discarded (no frame-buffer write), not wrapped or clamped —
matches MAME's `cliprect`-bounded blit.

**Nested loop / FSM structure**, in signal-flow order (state names indicative, not final):

```
S_IDLE
  -> frame_start: pulse walker's `start`
S_WALK_WAIT           -- wait for walker's entry_valid or done
  entry_valid -> latch sprite_index, pulse record_fetch's `start`
  done         -> frame_done, back to S_IDLE
S_RECORD_WAIT         -- wait for record_fetch's record_valid
  record_valid -> sprite_record_decode + sprite_pos_transform + both sprite_zoom_lut instances
                  all resolve combinationally in the same cycle (no wait needed);
                  reset ix=0, iy=0, subtile_ordinal=0
S_SUBTILE             -- sprite_subtile_step resolves combinationally (sub_x/sub_y/sub_code)
  -> issue spritelut ROM read at sub_code
S_LUT_WAIT            -- wait for lut_valid -> tile_code latched; reset dst_row=0
S_ROW                 -- sprite_zoom_src_index (Y instance) resolves src_row combinationally
  -> issue gfx ROM read at {tile_code, src_row, 3'b000}
S_ROW_WAIT            -- wait for gfxrom_valid -> tile_row_decode (flip_x=0) resolves combinationally;
                         reset dst_col=0
S_COL                 -- sprite_zoom_src_index (X instance) resolves src_col combinationally;
                         pixel = natural[src_col]; clip-and-write to frame buffer if opaque+onscreen
                  -> dst_col++; if dst_col == dst_size_x: dst_row++, back to S_ROW (or S_SUBTILE
                     if dst_row == dst_size_y: ix/iy/subtile_ordinal++ per the flip-aware nested
                     loop sprite_subtile_step expects (dy outer, dx inner, "Multi-tile sprite
                     composition" above), or back to S_WALK_WAIT with `advance` pulsed if the
                     sprite's whole nx*ny grid is done)
```

Every `_WAIT` state is a real multi-cycle round trip (BRAM/ROM latency); every other state is one
cycle of combinational resolution feeding the next request. `advance` to the display-list walker
is only pulsed once a sprite's *entire* sub-tile grid (all `nx*ny` sub-tiles, each with up to
`dst_size_x*dst_size_y` pixels) has been fully written to the frame buffer — this is the
"consumer is done with the held entry" signal the walker's flow control (see
`sprite_display_list_walker.sv`'s history) was built for.

**As built, the engine adds two timing-driven register stages to this sketch** (see
`sprite_render_engine.sv`): stage A captures every per-sprite constant (decode/pos-transform/
zoom-LUT outputs) once per sprite in `S_RECORD_WAIT`, and stage B registers the sub-tile
origin — both cut what was the design's worst `clk_sys` path without changing the FSM's
structure or throughput. A third cut (a stage registering the per-column zoom source index,
with the pixel mux/write moved a cycle later) was tried on 2026-08-29; it closed timing fully
but visibly regressed scene transitions on real hardware and was reverted — the S_COL
write-in-the-same-cycle shape above is the current, shipping behaviour. See
`docs/ROADMAP.md`'s "Timing closure" item.
