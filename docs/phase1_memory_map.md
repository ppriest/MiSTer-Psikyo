# Phase 1 Memory Map — SH201B / KA302C hardware

Scope: Samurai Aces / Sengoku Ace (`sngkace` machine config) and Gun Bird / Battle K-Road
(`gunbird` machine config) — the two board variants in scope for Phase 1 per
[docs/ROADMAP.md](ROADMAP.md). Both share one 68EC020 program memory map (`psikyo_map`,
psikyo.cpp:254) with small per-board overlays; they differ more in clocks and the sound-CPU
side. Strikers 1945 (protected or unprotected) and Tengai are out of scope here — noted only
where directly relevant (i.e. `s1945n_map` is a third overlay of the same base map, kept for
forward reference since it needs zero new video/sprite work later).

All addresses are byte addresses on the 68020's 32-bit address bus, verified directly against
`psikyo.cpp`/`psikyo_v.cpp` (not inferred/assumed) as of this writing.

## Clocks

| Signal | sngkace (Samurai Aces / Sengoku Ace) | gunbird (Gun Bird / Battle K-Road) |
|---|---|---|
| 68EC020 | `32_MHz_XTAL / 2` = 16 MHz | `16_MHz_XTAL` = 16 MHz |
| Sound CPU | Z80, `32_MHz_XTAL / 8` = 4 MHz | LZ8420M, `16_MHz_XTAL / 2` = 8 MHz |
| YM2610 | `32_MHz_XTAL / 4` = 8 MHz | `16_MHz_XTAL / 2` = 8 MHz |
| Pixel clock | `14.31818_MHz_XTAL / 2` ≈ 7.159 MHz (both boards, identical video timing) |

Screen: 320×224 visible, htotal 456, vtotal 262, ~59.923 Hz, 38 lines vblank (`set_raw`,
psikyo.cpp:1131/1173 — identical between boards).

Main CPU interrupt: `irq4_line_hold` on vblank (both boards) — a held, auto-vectored level-4
IRQ. TG68K.vhd already has the IPL/autovector machinery from the Phase 0 spike; this just needs
level 4 driven for one frame-tick and held until acknowledged.

## 68EC020 program address map

Base map (`psikyo_map`, shared, psikyo.cpp:254-266):

| Range | Size | Contents | Access |
|---|---|---|---|
| `0x000000–0x0FFFFF` | 1 MB | Program ROM (not all used — actual ROM size varies per game) | R |
| `0x400000–0x401FFF` | 8 KB | Sprite RAM (`spriteram`, hardware double-buffered — see below) | R/W |
| `0x600000–0x601FFF` | 8 KB | Palette RAM, `xRGB_555` format, 4096 entries (`PALETTE(...).set_format(xRGB_555, 0x1000)`, psikyo.cpp:1136) — 32-bit writes pack 2 entries each | R/W |
| `0x800000–0x801FFF` | 8 KB | Tilemap layer 0 VRAM | R/W |
| `0x802000–0x803FFF` | 8 KB | Tilemap layer 1 VRAM | R/W |
| `0x804000–0x807FFF` | 16 KB | Video registers ("RAM + Vregs" — see layout below) | R/W |
| `0xFE0000–0xFFFFFF` | 128 KB | Work RAM | R/W |
| `0xC00000–0xC0000B` | 12 B | Input ports — **overlay differs per board, see below** | R |
| `0xC00013` or `0xC00011` | 1 B | Sound latch write — **offset differs per board, see below** | W |

Everything at `0xC00000+` not listed for a given board is unmapped/logs a warning in MAME
(`logerror("Read input %02X !")`) — treat as open bus / don't-care for Phase 1 RTL, no game
logic depends on it.

### sngkace overlay (psikyo.cpp:350-355)

| Range | Contents |
|---|---|
| `0xC00000–0xC00003` | P1/P2 inputs (32-bit read, `sngkace_input_r` offset 0) |
| `0xC00004–0xC00007` | DIP switches (offset 1) |
| `0xC00008–0xC0000B` | Coin/service/vblank/z80-nmi-status inputs (offset 2) — **this board has a separate COIN port**, unlike gunbird below |
| `0xC00013` | Sound latch write |

### gunbird overlay — also covers Battle K-Road (psikyo.cpp:391-396)

| Range | Contents |
|---|---|
| `0xC00000–0xC00003` | P1/P2 inputs (32-bit read, `gunbird_input_r` offset 0) — coin/service/tilt/z80-nmi bits are folded into this port's upper bits instead of a separate COIN port |
| `0xC00004–0xC00007` | DIP switches (offset 1) |
| `0xC00013` | Sound latch write |

Note the sound latch write address differs from `s1945n_map` (`0xC00011`, forward reference
only, not this phase) despite `s1945n_map` otherwise being identical to `gunbird_map` — a real,
verified difference in the source, not a transcription risk this time (both confirmed directly
in psikyo.cpp:391-403).

Battle K-Road (`btlkroad`) uses the *exact same* `gunbird` machine config and `gunbird_map` —
confirmed via the `GAME()` driver table (psikyo.cpp:2110-2111), not assumed. Only its input
port *bit layout* within the P1/P2 and DSW words differs (6-button fighting game vs. shooter
controls) — a MRA/input-mapping concern for later, not a memory-map one.

## Sound CPU address maps

### sngkace (Z80, psikyo.cpp:357-371)

| Range | Contents |
|---|---|
| `0x0000–0x77FF` | Sound program ROM |
| `0x7800–0x7FFF` | Sound RAM |
| `0x8000–0xFFFF` | Banked ROM window (32 KB, `m_audiobank`, 4 banks — `sound_bankswitch_w<0>`, i.e. bank = `data & 0x03`, no shift) |

I/O (8-bit, `global_mask(0xFF)`):

| Port | Contents |
|---|---|
| `0x00–0x03` | YM2610 r/w |
| `0x04` | Bank select write (`sound_bankswitch_w<0>`) |
| `0x08` | Sound latch read |
| `0x0C` | Sound latch acknowledge write |

### gunbird / Battle K-Road (LZ8420M — treated as Z80-compatible, psikyo.cpp:405-419)

| Range | Contents |
|---|---|
| `0x0000–0x7FFF` | Sound program ROM |
| `0x8000–0x81FF` | Sound RAM (512 B — smaller than sngkace's) |
| `0x8200–0xFFFF` | Banked ROM window (**0x7E00 = 32,256 bytes — not a power of two**, verified exactly from the map bounds, don't round this up when writing the RTL address decode) |

I/O (8-bit, `global_mask(0xFF)`):

| Port | Contents |
|---|---|
| `0x00` | Bank select write (`sound_bankswitch_w<4>`, i.e. bank = `(data >> 4) & 0x03` — different shift than sngkace) |
| `0x04–0x07` | YM2610 r/w |
| `0x08` | Sound latch read |
| `0x0C` | Sound latch acknowledge write |

Sound latch behavior (both boards, psikyo.cpp:1148-1150/1189-1191): `GENERIC_LATCH_8`,
separate-acknowledge mode, latch-pending drives the sound CPU's **NMI** line directly (not a
regular IRQ) — the sound CPU wakes on NMI when the main CPU writes a command byte, reads it at
I/O `0x08`, and must write I/O `0x0C` to acknowledge/clear the pending line.

### samuraia/sngkace ADPCM-A sample ROM: bit 6/7 swap (`init_sngkace`, psikyo.cpp)

**Not yet implemented anywhere in this project — real gap, flagged here to close before Phase 1
sound bring-up.** MAME's `psikyo_state::init_sngkace()` applies a one-time fixup to the entire
`ymsnd:adpcma` ROM region at driver-init time, before the YM2610 core ever reads it:

```cpp
u8 *RAM = memregion("ymsnd:adpcma")->base();
int len = memregion("ymsnd:adpcma")->bytes();
/* Bit 6&7 of the samples are swapped. Naughty, naughty... */
for (int i = 0; i < len; i++)
{
    int x = RAM[i];
    RAM[i] = ((x & 0x40) << 1) | ((x & 0x80) >> 1) | (x & 0x3f);
}
```

i.e. `out[7]=in[6]`, `out[6]=in[7]`, `out[5:0]=in[5:0]` unchanged — bits 6 and 7 swap, nothing
else moves. This is a real-hardware artifact (how the actual sample ROM was mastered/wired on the
PCB, not an emulation convenience), so a real MiSTer core needs the equivalent transform or
Samurai Aces/Sengoku Ace's ADPCM-A samples will decode as garbage — everything else about their
sound path (Z80 program, YM2610 register access, sound latch/NMI) is unaffected.

**Scope — confirmed directly from the driver's `GAME()` table, not assumed:** only
`init_sngkace` applies this swap, and only these ROM sets use `init_sngkace`:

| ROM set | Swap applied? |
|---|---|
| samuraia, samuraiak, sngkace, sngkacea | **Yes** |
| gunbird, gunbirdk, gunbirdj, btlkroad, btlkroadk | No (`init_gunbird` — banking only) |
| s1945, s1945a, s1945j, tengai, tengaij | No (Phase 2, different init functions, no swap) |

Despite Gun Bird and Battle K-Road sharing identical SH201B/KA302C sound hardware (same Z80 +
YM2610, same address map above) with Samurai Aces/Sengoku Ace, they do **not** get this swap —
it's specific to how that one game's sample ROM was mastered, not a hardware-family property. A
per-game flag/select is required to gate it, not a hardware-group one.

**Where this belongs in the RTL, not decided yet:** the `.mra` format only expresses byte-level
ROM layout (offset/length/interleave/patch) — it cannot express an intra-byte bit permutation, so
this cannot be done in the `.mra` loader alone. Two real options:
1. Apply the swap during HPS ROM download (`ddram_download.sv`/`sdram_download.sv`'s byte-write
   path), conditionally on a per-game select signal, for bytes landing in the `ymsnd:adpcma`
   region — a one-time fixup at load time, directly mirroring what MAME's `init_sngkace` itself
   does, and cheap (no cost on the read/playback path at all).
2. Apply it on every ADPCM-A byte read on the way into jt10 — always-correct but pays a small
   combinational cost on every sample fetch for no benefit over option 1.
Option 1 is the natural fit given the project's existing download-path architecture. Needs a
per-game select bit/signal threaded from somewhere (status bit, `.mra` region metadata, or ROM
size/checksum detection) — how games are actually distinguished at the top level isn't decided
yet either (see ROADMAP.md's top-level integration item).

## Sprite RAM layout (`0x400000-0x401FFF`, both boards identical)

From `psikyo_v.cpp` (`get_sprites()`, `draw_sprites()`):

- **Sprite attribute table**: 768 (`0x300`) entries × 8 bytes = `0x1800` bytes, at
  `0x400000-0x401 7FF`. Per-entry format (big-endian, matches driver comments in
  `psikyo_v.cpp:145-183`):
  - Word 0 (`+0x0`): Y position + Y size/zoom nibble
  - Word 1 (`+0x2`): X position + X size/zoom nibble
  - Word 2 (`+0x4`): flags (flip X/Y bit 15/14) + color (bits 11-8) + priority (bits 7-6) +
    code high bit (bit 0)
  - Word 3 (`+0x6`): code low bits — full code then indexes into a **ROM lookup table**
    (`spritelut` region) to get the real tile code, not used directly
- **Display list**: word offsets `0xC00-0xFFE` within the 4096-word (8KB/2) spriteram region
  (byte `0x401800-0x401FFD`) — **1023** 16-bit sprite-table indices max (re-verified against the
  current source's loop bound `(0x800-2)/2 == 1023`, not the rounder "1024" an earlier pass
  through this doc estimated from byte-range arithmetic alone), terminated early by a `0xFFFF`
  sentinel. Sprite index is taken mod `0x300` (`sprite %= 0x300`).
- **Control word**: the very last word, word offset `0xFFF` (byte `0x401FFE`), doubles as flags
  rather than a display-list entry: bit 0 = sprites-disable (`if (ctrl & 1) return` — no sprites
  drawn this frame at all), bits 2-3 = transparent-pen select (bit 2 → pen 0, bit 3 → pen 15).
- **Hardware double-buffering**: MAME models this with `buffered_spriteram32_device`, copied on
  the vblank *rising* edge (`screen_vblank()`, psikyo_v.cpp:667-675) — i.e. the CPU-visible
  spriteram and the copy the sprite engine actually renders from are two separate buffers, swept
  once per frame. **This needs a real ping-pong buffer in RTL**, not just a single BRAM — the
  CPU can be mid-way through writing next frame's sprite list while the current frame is still
  being drawn from the previous copy.

## Tilemap VRAM (`0x800000-0x801FFF` layer 0, `0x802000-0x803FFF` layer 1)

8 KB each = 0x1000 words = 4096 tile-map cells (matches the largest configured tilemap
geometry, 256×128 tiles — see below). Per-cell format (`psikyo_v.cpp:71-86`):

- Bits 15-13: color code (0-7), plus a fixed `+0x40` per-layer offset baked into the gfx-decode
  color base (layer 1's colors are a separate palette bank from layer 0's)
- Bits 12-0: tile code, **plus `0x2000 * bank`** where `bank` (0-3) is a separate,
  vreg-selected tile-source bank (`switch_bgbanks()`) — i.e. the raw 13-bit code field only
  selects within a bank, the actual gfx ROM address needs the bank folded in externally
- Tile size: 16×16, 4bpp (from `psikyo.cpp` header comment: "Tiles: 16x16x4, Color Codes: 8")

**Geometry is dynamic, selected per-layer at runtime** via 2 bits in the vreg layer-control
word (see below), one of four fixed layouts, all mapping the same 4096-cell VRAM differently:

| Size code | Tilemap size (pixels) | Tiles (cols×rows) |
|---|---|---|
| 0 | 512×2048 | 32×128 (`0x20 × 0x80`) |
| 1 | 1024×1024 | 64×64 (`0x40 × 0x40`) |
| 2 | 2048×512 | 128×32 (`0x80 × 0x20`) |
| 3 | 4096×256 | 256×16 (`0x100 × 0x10`) |

The VRAM→screen address mapping per size code (`tile_scan<Layer>`, psikyo_v.cpp:88-98) looks
like a bit-interleave in the C++ source, but isn't one in practice: the caller
(`get_tile_info`) always masks the result with `& 0xFFF`, and every extra term in each case's
formula lands entirely above bit 11 — dead once masked. Worked this out numerically rather than
trusting the source's shape at a glance (see docs/phase1_video_engine.md, "Tilemap addressing"):
after masking, **all four modes reduce to plain row-major addressing**, `index = col + row *
width`, for `width` = 64/128/256/32 tiles respectively across the four size codes. Full detail
and verification in docs/phase1_video_engine.md.

## Video registers (`0x804000-0x807FFF`, 16 KB, both boards identical)

The region is genuinely dual-purpose ("RAM + Vregs" per the driver's own comment) — most of it
is scratch RAM the game uses freely, but specific fixed offsets are read every frame by the
video engine (`screen_update()`, psikyo_v.cpp:433-543):

| Offset (bytes) | Contents |
|---|---|
| `0x000-0x1FF` | Layer 0 per-line row-scroll table, 256× 16-bit X-scroll values (one per screen line, or one per *tile row* depending on a control bit — see below) |
| `0x200-0x3FF` | Layer 1 per-line row-scroll table, same format |
| `0x402` | Layer 0 Y scroll |
| `0x406` | Layer 0 X scroll (base, added to the row-scroll table value when row-scroll is active) |
| `0x40A` | Layer 1 Y scroll |
| `0x40E` | Layer 1 X scroll (base) |
| `0x412` | Layer 0 control word |
| `0x416` | Layer 1 control word |

Layer control word bits (both layers, same encoding — psikyo_v.cpp:443-454, driver's own
comment flags this as **"not quite right"**, i.e. MAME's own reverse-engineering is incomplete
here, worth keeping in mind as a ceiling on achievable accuracy per docs/ROADMAP.md):

| Bit(s) | Meaning |
|---|---|
| 0 | Layer enable |
| 1 | Opaque tiles (used in Gunbird's attract mode) |
| 3 | Transparent color select (pen 0 vs pen 15) |
| 6-7 | Tilemap size code (see table above) |
| 8 | Per-line row-scroll enable |
| 9 | Per-*tile* (as opposed to per-line) row-scroll |
| 10 | Tile bank select (only meaningful on `btlkroad`/`gunbird`/`s1945n` — `m_ka302c_banking` flag) |

## Open items for the RTL implementation phase (not memory-map questions, flagged here so they
aren't lost)

- Sprite double-buffering needs two BRAM banks + a swap-on-vblank-rising-edge control, not a
  single buffer.
- `tile_scan<Layer>`'s address bit-interleave per tilemap-size code needs to become either a
  combinational address-mangling function or 4 precomputed LUTs in RTL.
- The sprite code-to-tile-code indirection (`spritelut` ROM) means the sprite engine needs an
  extra ROM lookup stage before it can address graphics ROM, on top of the zoom/tile-walk logic.
- Palette format is `xRGB_555` (5 bits each, padded high bit unused) — confirms no per-pixel
  alpha/priority bits live in palette RAM itself; priority is entirely the 2-bit sprite priority
  field + tilemap draw order.
