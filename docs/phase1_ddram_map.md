# Phase 1 DDRAM integration — protocol and address map

**Superseded for real-time gfx/CPU ROM streaming by `docs/phase1_sdram_map.md`.** MiSTer's own
developer docs describe `DDRAM_*` as being for "non-critical time purposes" with high, *unbounded*
latency ("can be way longer" than the typical ~20 cycles), and real reference arcade cores of this
class use the physical `SDRAM_*` daughterboard for exactly the tile/sprite/CPU-fetch streaming
this doc's arbiter was built to carry — which was also this project's own original plan
(`docs/ROADMAP.md`'s "Component reuse map" already listed `SDRAM ctrl` before any RTL existed).
The protocol research and RTL below (`ddram_phy`/`ddram_arbiter`/`ddram_download`) are correct and
kept — the request/ack transport-layer design is directly reused by the new SDRAM arbiters — but
this is no longer the Phase 1 critical path for gfx/CPU ROM. See `docs/phase1_sdram_map.md` for
the full evidence trail and the active design.

Scope: the physical-ROM backing store for everything that isn't small enough to live in
on-chip BRAM (VRAM, spriteram, palette RAM stay on-chip, unaffected by this doc). Covers the
real MiSTer `DDRAM_*` interface protocol (verified against a working reference, not derived
from memory alone) and the address map this project's RTL will use — the counterpart to
`docs/phase1_memory_map.md` (which describes the *game's own* CPU-visible address maps) and to
the `.mra` files in `releases/` (which describe the *download blob* layout — see the note in
"Relationship to the `.mra` files" below for where those two designs currently disagree, and why).

## The DDRAM interface, as actually used

DE10-nano MiSTer cores don't have a physical SDRAM chip by default (`SDRAM_*` in
`sys/emu_ports.vh` is for an optional add-on daughterboard, tied to `'Z` in the untouched
`Psikyo.sv`). The real large-memory path is a slice of the HPS-side DDR3, reached through a
fixed Avalon-MM-style interface (`sys/emu_ports.vh:100-109`):

```
output        DDRAM_CLK,
input         DDRAM_BUSY,
output  [7:0] DDRAM_BURSTCNT,
output [28:0] DDRAM_ADDR,
input  [63:0] DDRAM_DOUT,
input         DDRAM_DOUT_READY,
output        DDRAM_RD,
output [63:0] DDRAM_DIN,
output  [7:0] DDRAM_BE,
output        DDRAM_WE,
```

Protocol, confirmed against a real, working MiSTer-devel core's `ddram.sv`
(`MiSTer-devel/TSConf_MiSTer/rtl/memory/ddram.sv`, fetched and read directly rather than
recalled from memory, since getting this wrong would be expensive to debug later):

- **64-bit-wide, 8-byte-aligned bus.** `DDRAM_ADDR` is a byte address with the low 3 bits
  dropped (`{4'b0011, byte_addr[27:3]}`) — every transaction reads/writes one 8-byte-aligned
  "granule" (or `DDRAM_BURSTCNT` granules in a row, `DDRAM_BURSTCNT=1` for a single granule).
  `DDRAM_BE` selects which byte lane(s) within a granule a write actually touches.
- **`{4'b0011, ...}` fixes the region base at HPS DDR3 offset `0x30000000`** — the standard
  MiSTer "extra RAM for core use" window (distinct from the Linux-visible region), giving
  cores up to 256MB (28-bit byte offset) of address space. This project's whole ROM/gfx
  footprint (see "Address map" below) is ~14MB, comfortably inside that.
- **Handshake**: assert `DDRAM_RD` or `DDRAM_WE` for one cycle while `DDRAM_BUSY` is low to
  start a transaction; `DDRAM_BUSY` stays high until it completes. For reads, the requested
  data appears on `DDRAM_DOUT` some cycles later, qualified by one `DDRAM_DOUT_READY` pulse.
  There is only ever one transaction in flight on the shared port — this is a single physical
  resource, not something each consumer gets its own copy of.
- **Latency is not fixed-cycle.** Unlike every on-chip BRAM port this project has built so
  far (1-cycle sync read) or the sprite/tilemap engines' own gfx ROM ports (already
  req/valid — see below), real DDR3 round-trip latency varies. Any consumer connected behind
  this interface needs a req/valid-style port, not a fixed-latency assumption.

## Good news: the video engines already speak req/valid

Checked directly against the built RTL rather than assumed: `tilemap_line_engine.sv`'s
`gfxrom_req/gfxrom_addr/gfxrom_valid/gfxrom_data` port and `sprite_render_engine.sv`'s
`gfxrom_req/.../gfxrom_valid/gfxrom_data` and `lut_req/.../lut_valid/lut_data` ports are
**already** latency-agnostic req/valid handshakes (matching this project's stated convention
for external memory interfaces, from day one of the video engine work) — not the fixed
1-cycle-sync convention used for on-chip VRAM/spriteram/palette ports. This means the DDRAM
arbiter below can serve these four ports directly, with no redesign needed on the consumer
side.

**Not yet true** of `sound_cpu_sngkace.sv`/`sound_cpu_gunbird.sv`'s `rom_addr`/`rom_data`
ports, which are today a plain 1-cycle-sync pair (matching their testbenches' simple
`always_ff` ROM models) with `WAIT_n` generation hardcoded to exactly one wait cycle. Both
will need converting to req/valid — and `WAIT_n` will need to stay asserted for a *variable*
number of cycles (until `rom_valid`) rather than exactly one — before they can sit behind this
arbiter. Tracked as an open item below; not done in this pass.

## Address map

One flat, fixed layout shared by every Phase 1 game — the RTL's address decode doesn't change
per game, only which bytes actually land in each region (and how much of it) does, driven by
whichever `.mra` is loaded. Region sizes are rounded up from the largest real content seen
across all four parent sets *and* their six MAME clone sets (`samuraiak`/`gunbirdk` in
particular have double-size 0x100000 `maincpu` ROMs, not just 0x80000 like their parents —
confirmed from `psikyo.cpp` while building `releases/_alternatives/`, not assumed), leaving
real headroom rather than packing tightly, so the map doesn't need to be revisited every time
a new clone set turns out to be slightly bigger:

| Region | Base (offset from `0x30000000`) | Size | Rounded up from |
|---|---|---|---|
| `maincpu` (68020 program ROM) | `0x000000` | `0x200000` (2MB) | `0x100000` (samuraiak/gunbirdk) |
| `audiocpu` (Z80/LZ8420M program ROM) | `0x200000` | `0x040000` (256KB) | `0x020000` (all sets) |
| `sprites` (zoom sprite tile gfx) | `0x240000` | `0x800000` (8MB) | `0x700000` (gunbird family) |
| `tiles` (tilemap layer 0+1 gfx) | `0xA40000` | `0x400000` (4MB) | `0x400000` (tengai, exact) |
| samples (`ymsnd:adpcma` / OPL4 wave) | `0xE40000` | `0x400000` (4MB) | `0x400000` (SH404, exact) |
| `ymsnd:adpcmb` (gunbird family only, inside samples) | `0xF40000` | `0x080000` (512KB) | `0x080000` (gunbird family, exact) |
| `spritelut` (sprite code lookup table) | `0x1240000` | `0x040000` (256KB) | `0x040000` (all sets, exact) |

Total reserved: `0x1280000` (18.5MB) — everything else is unused headroom. (Bases re-laid out
2026-08-30 for SH404 support, superseding the original 14MB map — see docs/phase2_sh404.md.)

Each region is a flat byte-addressed span; per-set content shorter than the region (e.g.
`btlkroad`'s 3-ROM/`0x600000` `sprites` vs. the `0x800000` reservation sized for gunbird's 4
ROMs) simply leaves the tail of that region unwritten/unused, not an error.

## Relationship to the `.mra` files

**The nine `.mra` files in `releases/` (and `releases/_alternatives/`) do not yet match this
map.** They were built before this doc existed, using a tightly-packed per-game concatenation
(each region immediately following the previous one, sized exactly to that game's own ROM
content) rather than this fixed-region-with-headroom layout — every one of those files says so
explicitly in its own header comment ("this project's OWN design choice for the SDRAM download
blob... not yet consumed by any RTL... may still change once that integration work actually
starts"). That integration work has now started (this doc + the arbiter RTL below), so the
`.mra` files need a follow-up pass to move each region to this doc's fixed base offset before
they'll actually load correctly against real top-level RTL. Tracked in `docs/ROADMAP.md`'s
Next steps; not done as part of this pass — writing the RTL and getting the address map right
first, since the `.mra` update is comparatively mechanical once the map is settled.

## Arbiter architecture

One physical `ddram_phy` port (the widened, req/valid-native equivalent of the verified
TSConf reference above) shared by a fixed-priority round-robin arbiter (`ddram_arbiter`)
serving:

- 2× tilemap layer `gfxrom` read ports (`tilemap_line_engine` instances)
- 1× sprite `gfxrom` read port (`sprite_render_engine`)
- 1× sprite `spritelut` read port (`sprite_render_engine`)
- (later, once the sound CPU wrappers are converted) 1× `audiocpu` program ROM read port per
  active sound CPU
- 1× HPS `ioctl_download` write port (active only during the ROM-loading phase before the
  core starts running, so it can safely take absolute priority over the read consumers without
  a real gameplay-time cost)

Each read consumer keeps its own already-established req/valid signature unchanged; the
arbiter's job is purely to time-multiplex those onto the one physical port and route
`DDRAM_DOUT`/`DDRAM_DOUT_READY` back to whichever consumer's request is currently in flight.

## Known open item: throughput, not just correctness

Real DDR3 round-trip latency (tens of cycles, not 1) applied to a shared port with up to 6+
consumers is a genuine bandwidth/latency budget question this doc does not attempt to answer
yet — same honesty-about-what's-unverified position as the sprite frame-renderer's own
unbudgeted throughput (`docs/ROADMAP.md`, "Open items"). Main CPU program fetch in particular
is latency-sensitive in a way gfx ROM streaming isn't (every stalled instruction fetch stalls
the whole 68020 pipeline) — worth flagging now rather than discovering it only once real
hardware bring-up exposes it as a framerate problem. Correctness first, matching this
project's practice throughout; a throughput pass is future work once real per-consumer access
patterns are known.

**No longer just theoretical — confirmed with a concrete test.**
`sim/video_pipeline_tb/tb_video_pipeline_ddram.sv` wires both tilemap layers' gfxrom ports
through the real `ddram_arbiter`/`ddram_phy` (not synthetic per-layer models) under sustained
operation, and reproducibly fails: with only *two* consumers (not the eventual 6+) and a
realistic 10-cycle model latency, both layers requesting a tile at the same moment (which they
routinely do, driven by the same `line_start`/`h_active` timing) forces the arbiter to fully
serialize them — ~13 cycles for one consumer's round trip, then ~13 more for the other, ~26
cycles total against each layer's 16-cycle-per-tile display budget. Confirmed via
waveform-equivalent tracing that this is exactly the predicted serialization mechanism, not a
wiring bug. Committed deliberately still failing, as concrete reproducible evidence for
whenever the throughput pass below happens (wider `ddram_phy` bursts and/or a prefetch-ahead
scheduling scheme) — that test should start passing on its own once the real fix lands, not
something to loosen its checks for in the meantime.
