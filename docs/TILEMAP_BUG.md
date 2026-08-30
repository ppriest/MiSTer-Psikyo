# Tilemap wrong-palette / tile-offset bug — findings (2026-08-29)

Status: **FIXED** (fix commit `f54e69b`, deployed as
`Arcade-Psikyo_20260864.rbf` 2026-08-29): the Gunbird attract cycle shows zero
wrong-palette green pixels (previously 149 on the title card alone) and the layer
offset is gone, confirmed visually on the real display.

## Root cause and fix

`tilemap_line_engine` cleared `gfxrom_req` one clock AFTER `gfxrom_valid` (registered
clear in `S_GFXROM_WAIT`); `rtl/memory/sdram_phy.sv` returns to `S_IDLE` on the valid
cycle itself and samples the still-high stale request — launching a **duplicate
transaction for the address it just served**. Every subsequent response the engine
consumed then belonged to the previous request: position N rendered cell N−1's tile
shape with N's own correctly-latched colour. First fetch of each line stayed correct
(the chain drains at line end). Not a timing violation — a deterministic handshake
protocol bug whose *visibility* is latency-dependent: the duplicate fired with the
short-latency behavioral ROM models too, but its response landed while the FSM was
between states and was silently dropped; the real controller's ~12+-cycle latency lands
it in the next `S_GFXROM_WAIT`. That is why every module-level sim passed while real
hardware failed.

Found by `sim/tilemap_addr_trace_tb/tb_tilemap_screen_sdram.sv` — the screen-path
testbench with the production SDRAM transport (`psikyo_sdram_top` verbatim +
`sdram_chip_model_wide`) substituted for the behavioral ROM: it reproduced the real
hardware screen **pixel-for-pixel** (149 green pixels, red bbox x[143,208] — identical
to the hardware measurements), and its transaction-address trace showed the phy serving
the previous request's address from the second fetch of every line onward.

Fix (`rtl/video/tilemap_line_engine.sv`): the request output is now gated
combinationally — `assign gfxrom_req = gfxrom_req_r & ~gfxrom_valid;` — so the phy
never sees the request high on the cycle its response arrives. Layer 0 inherits the fix
(same module). After the fix the reproduction TB renders byte-identical to the
known-good image and its trace shows zero stale responses; all sibling regressions pass.

The remainder of this file is the investigation record as it stood before the
mechanism was found.

## The bug, precisely

**One bug**: for the screen cell at tilemap position P (VRAM word index N), the core
renders the **tile number from word N−1** (one word behind) while taking the
**palette from word N (correct)**. Working theory — a single off-by-one on the
tile-number addressing — with two visible symptoms:

1. **Tile offset**: every tile's shape appears one cell late — the long-standing
   "one-tile X offset on both layers" bug (docs/LESSONS_LEARNED.md, "Don't guess a
   sign twice"), previously treated as separate, is this same displacement. MAME
   replicates the hardware's tile positions *exactly* when its VRAM is loaded shifted
   one word (`load l1_samurai-hiscore.bin,0x802002,0x2000` instead of `...2000`), which
   proves the stored data is correct and the displacement is on the core's read side.
2. **Wrong palette**: the displaced tile shape (from word N−1) is drawn at position P
   with position P's own palette (word N's color bits) — so each visible tile wears
   the palette belonging to the word *after* the one its shape came from. From the
   perspective of "the tile from word M, wherever it appears on screen", its palette
   comes from word M+1 — which is exactly what the JTAG pokes measured (below).

This is a logic bug in the tile-number addressing — not a feature, not timing, and
not two separate bugs.

## Live-hardware evidence (JTAG ISSP pokes, CPU paused)

Build: `Psikyo_stp` instrumented revision, deployed as `Arcade-Psikyo_20260863.rbf`.
Tools: `scripts/write_vram1.tcl` (instance "W" — word-aligned 16-bit VRAM1 writes, only
applied while the CPU is paused), auto-pause OSD switches (status[50] write-triggered /
status[54] frame-count, `scripts/arm_frame_pause.tcl`).

1. **Gunbird title screen** (layer-1 ctrl word `0x04D0`: mode 3 = 512×2048, bank 1,
   rowscroll off; x-scroll `0x0140`, y-scroll 0). Word `0x080` (byte `0x802100`) holds
   `0x2010` (tile 0x010 → 8208 with bank, own color bits = 1 → group 65). Rendered green
   (group 64's colors) instead of red (group 65's). Poking `0x2010` into word `0x081`
   (byte `0x802102`) **corrected the tile's colour** and made another tile appear.
2. **Samurai Aces hiscore table** (layer-1 ctrl `0x00D0`: mode 3, bank 0, rowscroll off,
   both scrolls 0). Word `0x101` (byte `0x802202`) holds `0xFCBF` (tile 0x1CBF = 7359,
   own color bits = 7). In MAME, changing it to `0x1CBF` (color bits 7→0) reproduces the
   red tile the hardware shows — i.e. hardware is using color bits 0, which is what
   neighbouring word `0x102` (0x0000) holds. Poking `0xFCBF` into word `0x102`
   (byte `0x802204`) **fixed cell 0x101's palette** (and made a tile appear one row up
   on the rotated screen). Poking `0xFCBF` into word `0x103` (byte `0x802206`) then
   **fixed cell 0x102's palette** in turn. Chained N/N+1 dependency, same direction both
   times, two games.

Both cases: pokes only ever corrected the **palette** of a displayed tile by writing
the word after its shape's source word. (An earlier reading of poke #2 as fixing the
"tile shape" was wrong — it was palette both times.) Under the unified theory this is
the expected observation: the poked word N+1 is the position where word N's tile shape
is (wrongly) displayed, so its color bits are what that shape wears.

## Ruled out (each with evidence, not inspection alone)

- **CPU write path**: excluded by the user (bug reproduces against MAME-verified VRAM
  content; MAME loaded with the same dump at a one-word offset reproduces the tile
  positions exactly, so the stored data is right and the read side is wrong).
- **`tilemap_line_engine.sv` fetch pipeline (RTL as simulated)**: `sim/tilemap_addr_trace_tb/
  tb_tilemap_addr_trace.sv` — real `dpram.sv` wired as production, self-describing VRAM
  pattern, 9 scenarios (all 4 geometry modes, banks 0/1/3, rowscroll line/per-tile, plus
  the exact Gunbird title config mode3/bank1): 189 fetched cells + 2880 displayed pixels,
  zero tile/color source-word splits, fetch side and display side (prefetch ring buffer
  indexing) both checked independently.
- **Same, with real data**: `tb_tilemap_real_data.sv` — the actual captured Gunbird VRAM
  (`real_vram1_dump.hex`) and real config; the target cell 0x080 decodes tile=8208 /
  color=65, correct, in sim. Display side traced across the mode-3 wrap boundary
  (col 31→0): clean. (Wrap is not the mechanism anyway — the Samurai case is nowhere
  near a wrap.)
- **Timing** (ruled out): two independent ways.
  1. *Structural*: `tile_cell_decode.sv` derives tile_number and color as plain bit-slices
     (`[12:0]`, `[15:13]`) of ONE registered word — there is no path by which lateness can
     split them; a late/violating address changes which whole word is captured, wrong for
     both fields together, never selectively.
  2. *Empirical*: `tb_tilemap_timing_injection.sv` sweeps an injected delay on the VRAM
     read address from 0 to 100 ns (clock period 10 ns — far past any real violation,
     and past the deployed build's worst measured slack of −2.83 ns which is on an
     unrelated sprite-engine path anyway): **zero** selective (tile-OK/color-wrong)
     corruptions at any delay; at ≥20 ns the failure mode is a uniform whole-word shift,
     both fields wrong together. The observed symptom cannot be produced by delay on
     this path.
- **`tilemap_addrgen.sv` / `tilemap_coord.sv`**: no ±1 constant anywhere (symmetric
  mask/bit-select only), previously exhaustively brute-force verified by sim, re-verified
  in all the above scenarios. Memory-layout dumps also look correct per the user.
- **`compositor.sv`**: purely combinational (no registers — cannot desynchronize its own
  inputs), wiring in `psikyo_core.sv` checked (no layer swap), and exercised with real
  data in-sim (below) with correct output.
- **GFX ROM interleave / decode**: verified — full-tilemap render from real ROMs is
  pixel-correct (below). Note the tiles region for gunbird is **u33.bin** (the
  u14/u24/u15/u25 set is sprite gfx; MRA byte-offset arithmetic puts u33 exactly at
  `TILES_BASE` 0x0A40000).

Key open contradiction: **simulation of every suspected module, alone and with real
data, renders correctly — the bug exists only on real hardware.** Whatever the
mechanism, it lives in a seam not yet covered by these testbenches (or a
synthesis-vs-RTL divergence). The next step (below) closes the largest remaining
coverage gap: the full screen-path integration (scroll, rowscroll, windowing,
line sequencing) rather than isolated modules.

## Tools / artifacts checked in

Debug infrastructure (RTL, `Psikyo_stp` build only, all `DEBUG_ISSP`-gated):
- `rtl/psikyo_core.sv` — VRAM1 JTAG write probe (ISSP instance "W"), write-triggered
  auto-pause (status[50], fires on CPU write of 0x2010 to word 0x080), frame-count
  auto-pause (status[54] + ISSP instance "F").
- `scripts/write_vram1.tcl` — poke/readback for VRAM1 over JTAG (see header for usage).
- `scripts/arm_frame_pause.tcl` — arm/read the frame-count auto-pause.
- Trace overlay (status[56], pre-existing): rows 0–31 VRAM0/1, 32–47 vregs, 48–63
  palette RAM — a single screenshot carries all four memories; this is where every
  "real captured" hex file below came from.

Captured data (all from the live paused Gunbird title screen unless noted):
- `sim/tilemap_addr_trace_tb/real_vram1_dump.hex` — layer-1 VRAM, 4096 words.
- `sim/tilemap_addr_trace_tb/real_palette_dump.hex` — palette RAM, 4096 words.
- `sim/tilemap_addr_trace_tb/u33_swapped.hex` — gunbird tiles ROM (u33.bin) with the
  MRA `map="12"` pairwise byte swap pre-applied. (Generated from `roms/gunbird.zip`,
  not committed; regenerate with the one-liner in TILEMAP_BUG's history or the
  extraction code in git log.)
- `debug/mame_dumps/l0_samurai-hiscore.bin`, `l1_samurai-hiscore.bin`,
  `lr_samurai-hiscore.bin` — MAME dumps of both tilemap VRAMs + vregs at the Samurai
  Aces hiscore screen (big-endian byte order; `lr` = vreg region, L1 ctrl at word
  0x20B). Source of evidence case #2.
- `debug/trace_overlay_dump.png` — the raw overlay screenshot the Gunbird hex dumps
  were decoded from.

Testbenches (`sim/tilemap_addr_trace_tb/`, share the sibling `modelsim.ini`; run vsim
from that directory; compile everything `+define+DEBUG_ISSP`):
- `tb_tilemap_addr_trace.sv` — 9-scenario fetch+display self-consistency sweep.
- `tb_tilemap_real_data.sv` — real-data replay of the Gunbird title config, wrap-boundary
  display-side trace.
- `tb_tilemap_timing_injection.sv` — the delay-injection sweep that rules out timing.
- `tb_tilemap_full_dump.sv` — decodes all 4096 cells through the real RTL
  (tile_cell_decode → tile_row_decode → compositor + real palette dpram, real ROM hex)
  and writes `full_tilemap_dump.txt` (RTL-computed RGB per pixel); assembled into
  `debug/full_tilemap_layer1_rtlpal.png` (+`_top` crop) — a fully-RTL-rendered, correct
  image of the whole 512×2048 layer-1 map, proving decode/palette/ROM handling end to
  end *outside* the screen-path pipeline.

## Next step

A full **screen-path** integration test: render layer 1 for the Gunbird title case all
the way to screen coordinates — through the real `tilemap_line_engine.sv` line
sequencing with the real scroll x/y and rowscroll inputs, clamped to the 320×224
screen, using the real captured VRAM/vregs/palette and real ROM data, project RTL only
(no test-only shortcuts in the rendered path) — and compare against the on-hardware
screenshot. If the sim screen image is correct where hardware is wrong, the divergence
is between RTL and silicon (synthesis/optimization); if the sim reproduces the bug,
the mechanism is in the screen-path integration seams that the per-module tests above
bypass (line_start/vcnt sequencing, vreg latching, scroll application, or the
psikyo_core wiring between them).
