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
                                         ---c ba98 ---- ----   color (4 bits)
                                         ---- ---- 76-- ----   priority (2 bits) -- see below
                                         ---- ---- ---- ---0   code, high bit
+0x6 (word): code low bits              full 17-bit raw code = (bit0 of +0x4) << 16 | (+0x6)
```

Position sign convention (verified against the C++, not a standard two's-complement 9-bit
field — this is easy to get subtly wrong): raw 9-bit field `0-511`; **values `0x180-0x1FF`
(384-511) are reinterpreted as `-128..-1`**, everything else (`0-383`) stays positive as-is.
This is an asymmetric range (positive extent 383px, negative extent only 128px) sized exactly
to let a sprite be scrolled 128px off the left/top edge without needing full two's-complement
range. Do not implement this as a naive sign-bit check on bit 8 — that would flip at 256, not
384, and would be wrong.

Zoom: raw 4-bit field `0-15` (0 = full size). Effective scale = `(32 - raw) / 32`, i.e. raw 0 →
100%, raw 15 → 17/32 ≈ 53% (matches the driver's "shrinks to ~50%" comment). Both X and Y zoom
independently.

**Code → gfx ROM tile number is indirected through a ROM lookup table** (`spritelut` region,
loaded from its own ROM), not used directly. This is a real extra pipeline stage the RTL sprite
engine needs: raw 17-bit code → LUT read → actual gfx ROM tile address. The LUT lookup happens
**per 16×16 sub-tile**, not once per logical sprite (see next section) — the raw code
increments once per sub-tile, and each incremented value is independently looked up.

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
pipeline (fetch one 16×16 tile, zoom-scale it, blend it into the line buffer at its computed
position) iterated up to 64 times per sprite, rather than needing an arbitrary-size 2D scaling
engine. The zoom scaling itself (16×16 source → variable-size destination) is the one genuinely
hard, novel piece of hardware here — no existing MiSTer core's zoom-sprite implementation can be
directly reused (CAVE's is conceptually the closest analog per docs/ROADMAP.md, but Chisel/
different toolchain, so it's design inspiration only).

## Sprite double-buffering

Hardware double-buffers the whole 8 KB spriteram, swept on vblank's *rising* edge
(`screen_vblank()`, psikyo_v.cpp:667-675; also flagged in docs/phase1_memory_map.md). RTL needs
two independently-addressable 8 KB BRAM banks with a bank-select flip-flop toggled once per
frame, not a single buffer — the CPU can be actively writing next frame's list into one bank
while the sprite engine is still reading the other bank's contents for the frame currently being
scanned out.

## Priority / compositing

Draw order (psikyo_v.cpp:522-540): layer 0, then layer 1, then sprites — each tilemap layer's
opaque pixels write a fixed category value into a shared priority bitmap (layer 0 → 1, layer 1
→ 2) as it's drawn, and sprites are gated against that priority bitmap by a `primask` derived
from the sprite's 2-bit priority field via a fixed table `{0, 0xFC, 0xFF, 0xFF}`
(psikyo_v.cpp:189).

Working through what that table actually does against a priority bitmap that only ever holds
`0` (nothing drawn), `1` (layer 0), or `2` (layer 1) — this is standard MAME `prio_transmask`
convention (pixel drawn iff `(dest_priority & primask) == 0`), worth confirming against
`drawgfxm.h`'s exact semantics when implementing rather than trusting this write-up blind, but
straightforward to work out from the table values themselves:

| Sprite priority field | primask | `primask` bits vs. tilemap priority values (1, 2) | Net effect |
|---|---|---|---|
| 0 | `0x00` | never blocks (mask is all-zero) | always drawn in front of both tilemap layers |
| 1 | `0xFC` (`11111100`) | bits 0-1 clear → never matches tilemap's 1 or 2 | **same as priority 0** — always in front |
| 2 | `0xFF` | matches any nonzero priority | blocked wherever *either* tilemap layer drew opaquely — i.e. always **behind** both layers |
| 3 | `0xFF` | same as 2 | same as priority 2 — always behind both layers |

So in practice this hardware only has **two** sprite priority tiers relative to the tilemaps —
"always in front of both layers" (field 0 or 1) or "always behind both layers, only visible over
background" (field 2 or 3) — not four independent priority levels, and no "between layer 0 and
layer 1" option. Simpler than the raw 2-bit field might suggest; good to know before designing
the compositor's priority logic (a single front/back select per sprite, not a 4-way priority
mux).

## RTL module breakdown (proposed, not yet implemented beyond the address-generation math above)

1. **Tilemap engine** (×2 instances, one per layer) — address generator (trivial per above) +
   VRAM read + gfx ROM tile fetch + row-scroll prefetch + horizontal line-buffer shift register.
   The simplest of the three major pieces; good first implementation target.
2. **Sprite engine** — double-buffered spriteram, display-list walk, per-sub-tile zoom-blit
   pipeline, spritelut ROM indirection. The hard, novel piece.
3. **Compositor** — 2-tier priority mux (front/back sprite select) + palette lookup +
   transparent-pen handling, feeding the video output timing generator.

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
