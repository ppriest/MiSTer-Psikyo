# Phase 1 SDRAM integration — protocol, address map, and why this replaces DDRAM

**Supersedes `docs/phase1_ddram_map.md` as the active design for real-time gfx ROM streaming.**
That doc isn't deleted (its DDRAM protocol research is correct and may still be useful for a
future non-critical-path use — see its own new header note), but the transport this project
actually builds against for tile/sprite graphics is the one in this doc, for reasons below.

## Why the pivot (evidence, not a hunch)

This session built a complete DDRAM transport stack (`ddram_phy`/`ddram_arbiter`/
`ddram_download`) and then hit a confirmed throughput failure
(`sim/video_pipeline_tb/tb_video_pipeline_ddram.sv`): two tilemap layers requesting
simultaneously forced the arbiter to fully serialize ~26 cycles of DDR latency against a
16-cycle-per-tile budget. Before designing a fix for that specific number, it's worth being
honest about what the number actually measures: that testbench (like `video_timing.sv`'s own
convention) drives `ce_pix = 1'b1` — i.e. it runs the whole design, DDRAM model included, at a
literal 1:1 ratio between the system clock and the 7.159MHz pixel clock. A real top-level would
run `clk_sys` much faster (Template_MiSTer cores are typically ~50-100MHz) and gate pixel-domain
advancement with a real `ce_pix` pulse, giving something like 14x more actual clock cycles per
tile-display-period than the raw "16" the failing test measured against. So the specific "26 > 16"
number is a testbench-fidelity artifact, not necessarily a real hardware verdict — worth recording
here so nobody re-derives false urgency from that exact number later, and worth fixing in that
testbench regardless of the rest of this doc (tracked in ROADMAP.md).

That caveat does **not** change the underlying conclusion, for reasons independent of any specific
cycle count:

1. **MiSTer's own developer documentation says so directly.** Fetched
   `mister-devel.github.io/MkDocs_MiSTer/developer/emu/` directly (not recalled): DDR3/`DDRAM_*`
   is documented as being for **"non-critical time purposes"**, with **"High latency"** — "Every
   read request will have a latency of multiple cycles. Something like 20 cycles @ 100Mhz is a
   typical value, **but it can be way longer**." That last clause is the real problem: DDR3
   latency on the DE10-nano is shared with the HPS/Linux side and is not just high but
   **unbounded in the worst case**, which makes it fundamentally unsuited to a hard real-time
   per-tile fetch budget no matter how generous the average-case cycle count is — a budget built
   against an average can still blow up on an unlucky frame. The same page recommends `SDRAM_*`
   as the lower-latency interface and cites real cores using direct SDRAM access for tile/sprite
   data.
2. **Real, comparable reference cores confirm this in practice.** Sorgelig's `sdram.sv` (GPLv3,
   2018) — vendored directly into dozens of MiSTer-devel arcade cores, including
   `Arcade-Jackal_MiSTer` (fetched and read directly) — exposes **3 independent, fixed ~6-7-cycle-
   latency ports** against the physical SDR SDRAM daughterboard (MT48LC16M16, 32MB). Fixed,
   bounded latency, not "can be way longer." This is the same class of shmup-era arcade hardware
   this project is already modeled on.
3. **This was the original plan.** `docs/ROADMAP.md`'s own "Component reuse map" (written before
   any RTL existed this project) already lists `SDRAM ctrl` under the top-level framework row and
   the Phase 1 description already says **"SDRAM tile/sprite ROM banking."** The DDRAM stack built
   earlier this session was itself the deviation from that plan, not the other way around — this
   pivot is a correction back to the documented intent, not a new direction invented mid-project.

Conclusion: gfx ROM streaming (tilemap gfxrom ×2, sprite gfxrom, spritelut) moves to `SDRAM_*`.
`maincpu` program fetch — the single most latency-sensitive consumer of all, since every stalled
68020 fetch stalls the whole pipeline — and `audiocpu` also move to SDRAM for the same reason.
DDRAM's role for this project, if it has one at all in Phase 1, shrinks to genuinely non-critical
uses the docs describe it for (e.g. a future save-state/NVRAM path) — not decided yet, not needed
for Phase 1 bring-up, not blocking anything below.

## The real SDRAM_* interface, as actually used

DE10-nano's `SDRAM_*` pins (`sys/emu_ports.vh`, confirmed against `Template_MiSTer/sys/sys_top.v`
directly) go to the physical MiSTer SDRAM add-on board (SDR SDRAM, `MT48LC16M16` — 16M×16, i.e.
32MB total, 2 banks × 13-bit row × 16-bit-wide data):

```
inout  [15:0] SDRAM_DQ,
output [12:0] SDRAM_A,
output        SDRAM_DQML,
output        SDRAM_DQMH,
output  [1:0] SDRAM_BA,
output        SDRAM_nCS,
output        SDRAM_nWE,
output        SDRAM_nRAS,
output        SDRAM_nCAS,
output        SDRAM_CLK,
output        SDRAM_CKE,
```

Reference controller (Sorgelig's `sdram.sv`, fetched from `Arcade-Jackal_MiSTer/rtl/ram_rom/`):

- **3 independent client ports** (`addr0/1/2[24:1]` word address, `wrl/wrh` byte-lane write
  masks, `din[15:0]`, `dout[15:0]`, `req`, `ack`), internally arbitrated port0→port1→port2
  priority when idle.
- **Req/ack is a level-compare (toggle) handshake, not a pulse/valid pair**: a client starts a
  transaction by driving `req != ack` (i.e. toggling `req`); the controller accepts it, and when
  done sets `ack <= req` (equal again) in the *same* cycle it latches `dout`. This is a different
  convention from this project's established req(hold)/valid(pulse) pattern used everywhere else
  (`ddram_phy`, `tilemap_line_engine`'s gfxrom port, etc.) — the `sdram_phy` wrapper below exists
  specifically to translate between the two, so every consumer keeps the one familiar interface.
- **Fixed latency, not variable**: with `RASCAS_DELAY=2`/`CAS_LATENCY=2` (this reference's real
  parameters, not assumed), request-to-ack is consistently ~6-7 cycles at up to 128MHz. No
  refresh-induced or ARM-contention-induced spikes — the whole point of using the daughterboard.
- **No burst support in this exact reference** (`BURST_LENGTH=3'd0`, single access only,
  confirmed by reading the read-side state machine directly — it only ever latches one word per
  transaction regardless of the mode-register field). This matters for us: see "The 64-bit
  granule problem" below.

## The 64-bit granule problem (real design issue, not a copy-paste job)

Every existing gfx ROM consumer in this project (`tilemap_line_engine.gfxrom_data`,
`sprite_render_engine.gfxrom_data`/`lut_data`) speaks in 64-bit granules — one packed row of a
4bpp 16-pixel-wide tile. `SDRAM_DQ` is only 16 bits wide. Naively doing 4 sequential single-access
transactions per granule (no bursting) costs ~4×7=28 cycles *with zero contention*, which is worse
than the DDRAM path this doc is replacing, not better — so this is not a drop-in swap.

Sorgelig's reference doesn't help here directly: its read-side FSM captures exactly one word per
transaction no matter what the mode register's burst-length field says (checked directly, not
assumed — flipping the parameter alone would desync the controller from the chip's own internal
burst counter and cause real bus contention on `SDRAM_DQ`). A correct fix needs the read-side FSM
extended to actually drive a multi-word burst read (mode register burst length = 4, CAS latency
still applies once, then the SDR chip streams 4 words out on consecutive clocks) and capture all 4
words into one combined 64-bit `dout`. This is genuine new RTL, verified the same way every other
module in this project has been (behavioral SDR chip model exercising real `nRAS`/`nCAS`/`nWE`/
`SDRAM_A`/`SDRAM_BA` command sequencing, not a black-box latency stub) — not a search for an
existing burst-capable reference to copy, since a broad search this session didn't turn one up
that matches this project's exact granule/port shape.

The natural mitigation for why this is safe to build (not just "we'll wing the SDR timing"):
tile-row data for consecutive fine_y values of one tile IS physically contiguous in ROM
(`tile_number*128 + fine_y*8`, confirmed in `tile_row_decode`'s header), and a 64-bit granule
IS exactly 4 consecutive 16-bit words at that base address — genuinely sequential, textbook
burst-mode use, not a burst bolted onto a random-access pattern.

## Address map

Same flat per-region layout as `docs/phase1_ddram_map.md`'s table (region base offsets and sizes
are backend-agnostic — they're a byte-address convention for `.mra` and RTL address decode either
way), reinterpreted as byte offsets into the 32MB SDRAM chip instead of the 256MB DDR3 window:

| Region | Base | Size |
|---|---|---|
| `maincpu` | `0x000000` | `0x200000` (2MB) |
| `audiocpu` | `0x200000` | `0x040000` (256KB) |
| `sprites` | `0x240000` | `0x800000` (8MB) |
| `tiles` | `0xA40000` | `0x400000` (4MB, tengai) |
| samples (`ymsnd:adpcma` / OPL4 wave) | `0xE40000` | `0x400000` (4MB) |
| `ymsnd:adpcmb` (inside samples) | `0xF40000` | `0x080000` (512KB) |
| `spritelut` | `0x1240000` | `0x040000` (256KB) |

Total `0x1280000` (18.5MB) of the SDRAM chip's 32MB — comfortably inside. Regions are sized for
the largest set that ships in them (docs/phase2_sh404.md "SDRAM re-layout"; re-laid out
2026-08-30 for tengai's 4MB tile ROM — the `.mra` padding and these bases must change
together). The
nine `.mra` files in `releases/` don't need to change at all for this pivot — they describe the
download blob layout, which is backend-agnostic.

## Arbiter architecture (3 physical ports, 7 logical consumers)

Sorgelig's controller gives exactly 3 physical ports. This project needs to serve 7 logical
consumers eventually (2 tilemap gfxrom, sprite gfxrom, spritelut, maincpu, audiocpu, HPS
download). **Revised after real measurement, not just design intent** — see "Verification
results" below: the two tilemap layers must NOT share a port, because they're exactly the
consumers `tb_video_pipeline_ddram.sv` proved contend simultaneously (same `line_start`/
`h_active` timing driving both):

| Physical port | Logical consumers | Arbitration |
|---|---|---|
| Port 0 | Tilemap layer 0 gfxrom | dedicated, no arbiter |
| Port 1 | Tilemap layer 1 gfxrom | dedicated, no arbiter |
| Port 2 | Sprite gfxrom, sprite spritelut, `maincpu` program fetch, `audiocpu` program fetch, HPS `ioctl_download` | 5-way, `sdram_arbiter5.sv` — built and verified, see "Port 2: built and measured" below |

**SUPERSEDED — the table above is the partition as first built, kept for the verification
narrative below. The current partition** (a 2026-08-29 repartition aimed at the sprite-render
slowdown; measured WORSE on that metric and still under evaluation — see `docs/ROADMAP.md`'s
"Fix the slowdown" item — but it is what `rtl/memory/psikyo_sdram_top.sv` wires today) **is:**

| Physical port | Logical consumers | Arbitration |
|---|---|---|
| Port 0 | BOTH tilemap layers' gfxrom | `sdram_arbiter2.sv` |
| Port 1 | Sprite gfxrom | dedicated — via a single-client pulse shim (`SP_IDLE`/`SP_ISSUE`/`SP_WAIT`), because `sdram_phy` expects a one-shot req and a held req silently returns stale data (see LESSONS_LEARNED's req/valid-transport bullet) |
| Port 2 | ADPCM-B (delta-T), spritelut, `maincpu`, `audiocpu`, ADPCM-A, HPS `ioctl_download` | 6-way, `sdram_arbiter6.sv` (clients c0-c4 + the absolute-priority download path) |

This spends the "no shared port" property on the two consumers *proven* to contend (the tilemap
layers), and accepts contention on Port 2 for consumers that don't have that same
synchronized-simultaneous-request pattern. Real sprite/CPU contention numbers are now measured
(not assumed) — see below.

## Verification results (real measurement, not assumed)

`sim/video_pipeline_tb/tb_video_pipeline_sdram.sv` — the direct SDRAM counterpart to the
DDRAM test that started this pivot — went through three real iterations, not a single
assumed-correct pass:

1. **Shared port** (both tilemap layers through one `sdram_arbiter2`, matching the *original*
   draft of the table above): **370/954 mismatches (39%)**. A large, real improvement over
   DDRAM's 954/954 (100%), but not a full fix — SDRAM's ~15-cycle uncontended latency still
   costs much more when two consumers serialize through one arbitrated port.
2. **Dedicated ports** (each layer given its own physical port, no arbiter — the table above,
   as revised): **189/954 mismatches (20%)**. Confirms removing the *arbiter* is the right
   direction, but not sufficient on its own — see below for why.
3. **Widened prefetch buffer** (`tilemap_line_engine`'s `PREFETCH_DEPTH` raised from a fixed
   2-entry ping-pong to an 8-entry ring — see that module's own header comment): **0/12720
   mismatches, clean PASS, over 40 sustained lines** (widened from the original 3-line check
   specifically to give the periodic stall below many chances to recur).

**Root cause of the residual 20%, measured directly, not guessed**: "dedicated ports" only
separates the address/data *buses* — `rtl/memory/sdram/sdram.sv`'s actual read-capture pipeline
(`state`/`dout`/`ram_req`) is a single shared resource across all 3 of its logical ports, since
it's ultimately one physical SDR SDRAM chip with one data bus. Instrumenting the testbench to
measure layer 1's real per-tile `gfxrom_req`-to-`gfxrom_valid` latency showed a bimodal
distribution: **~15 cycles nominal** (fits the 16-cycle budget with 1 cycle to spare), but
**~22 or ~35 cycles on roughly 1-in-5 tiles**, exactly when layer 0's simultaneous,
same-`line_start`-timing request forced layer 1 to wait out layer 0's transaction first (direct
port0-beats-port1 arbitration-loss counts and the latency histogram were both captured, not
inferred). With only one tile ever banked ahead of display, each such stall was an immediate
visible miss — 1-in-5 tiles failing lines up almost exactly with the measured 20% pixel failure
rate. Widening the prefetch to 8 entries gives up to 7 tile-periods (~112 cycles) of absorption
instead of 1 (~16), enough to ride out these stalls; empirically confirmed clean, not just
theorized.

This is a real, verified fix for the exact contention pattern this test exercises (two
same-timing layers, sustained, worst-case), but it is not a formal proof that no contention
pattern can ever exceed an 8-entry buffer — the SDRAM controller's single shared pipeline is a
genuine hardware constraint (one physical chip) that a deeper buffer works around, not removes.
The architecturally "correct" long-term fix remains a genuinely faster, independently-clocked
fetch domain (real CDC), or a redesigned/pipelined SDRAM controller that can overlap transactions
across ports — both larger, separate tasks, not needed to close out Phase 1's tilemap path today.

**Important negative result along the way, saves future time**: tried making the testbench's
`ce_pix` a realistic ~1-in-14 divider (matching a ~100MHz `clk_sys` against the real 7.159MHz
pixel clock) instead of `1'b1`. This made things dramatically WORSE (12426/13356 mismatches), not
better, because `tilemap_line_engine` has no `ce_pix` input at all — it consumes one buffered
pixel per raw `clk` cycle, gated only by `h_active`. Under a divided `ce_pix`, `h_active` stays
high for 14 consecutive `clk` cycles per real pixel, and the engine raced through its entire
prefetch buffer in a fraction of the intended time, completely desyncing from `video_timing`.
This proves the pixel-domain engines (`tilemap_line_engine`, and presumably
`compositor`/`sprite_render_engine`) are designed for `clk` == pixel clock throughout, a
single-clock-domain video pipeline — not a fast `clk_sys` with a `ce_pix` gate sprinkled on top.
`ce_pix=1'b1` in these testbenches is therefore the *correct* model of the current RTL's real
behavior, not a simplification to fix. A genuinely faster fetch-domain clock (the long-term fix
above) would need explicit CDC design work in the video engines themselves, not just a testbench
clocking change — a real, separate design task, still open.

## Port 2: built and measured

`sdram_arbiter5.sv` reuses `ddram_arbiter.sv`'s design byte-for-byte (same hold-until-ack
round-robin among 4 read consumers, same absolute-priority download write path) — the only real
difference from `sdram_arbiter2.sv` is one more read consumer and `sdram_phy`'s 25-bit address
width. Verified in isolation (`sim/sdram_arbiter5_tb/tb_sdram_arbiter5.sv`, same 4 cases as
`tb_ddram_arbiter.sv`) against the *real* SDRAM transport (`sdram_phy`/`sdram`/
`sdram_chip_model`), not a stub — clean pass on the first run, unsurprising given the design is a
direct reuse of an already-verified pattern.

**The narrow-consumer problem.** Only sprite gfxrom is naturally 64-bit-granule-shaped (its
address always ends `3'b000`, same as tilemap gfxrom). Spritelut (16-bit words), `maincpu`
(16-bit fetch), and `audiocpu` (8-bit fetch) are all narrower than the 64-bit granule
`sdram.sv`'s burst-4 read always returns. New, reusable RTL: `sdram_narrow_bridge.sv`
(parameterized `WORD_BYTES=1` or `2`) fetches the containing 8-byte granule and extracts the
requested byte/word, verified against real SDRAM transport at every one of the 8 byte positions
and 4 word positions in a granule (`sim/sdram_narrow_bridge_tb/`) — including a genuine bug this
test caught in itself (a Verilog concatenation width-truncation mistake in the *test's own*
expected-value computation, not the RTL; `8'hA0 + int_expr` silently widens to 32 bits inside a
`{}` — fixed with explicit 8-bit intermediates, documented inline as a caution for future tests).

**Real bug found and fixed: gfx ROM byte order.** Building `sim/port2_sdram_tb/tb_port2_sdram.sv`
— real `sprite_render_engine` (gfxrom + spritelut) driven through `sdram_arbiter5` with genuinely
non-uniform gfx ROM content (a gradient tile, not the all-zero pattern every prior SDRAM video
test used) — immediately failed with obviously-scrambled pixel data. Root cause: `sdram.sv`'s
burst-4 read capture packs bytes in ordinary ascending-address-to-ascending-bit-position order
(confirmed directly from `sim/sdram_tb/tb_sdram.sv`'s own passing Case 1: the lowest-address
seeded word lands in `dout`'s *low* 16 bits) — correct, and already relied on by
`sdram_narrow_bridge.sv` for ordinary little-endian ROM words. But `tilemap_line_engine.sv` and
`sprite_render_engine.sv` both build `row_bytes[]` from `gfxrom_data` assuming the **opposite**
convention (MSB-first, matching MAME's `gfx_16x16x4_packed_msb` tile format, correctly documented
and unit-tested against synthetic ROM models that used that same MSB-first packing). Neither side
was wrong on its own — they were each independently correct against self-consistent but opposite
conventions, and the mismatch only exists at the seam between them. `sim/video_pipeline_tb/
tb_video_pipeline_sdram.sv` (the tilemap SDRAM test, already committed and passing) never caught
this because its gfx ROM content was uniform all-zero, which is byte-order-invariant — a real,
previously-invisible gap in that test's coverage, not a flaw in its pass result.

Fix: `rtl/memory/gfxrom_byte_reorder.sv`, a small combinational adapter (reverses the 8 bytes of
a granule) inserted at the integration seam between `sdram.sv`'s native output and any gfx-ROM-row
consumer's `gfxrom_data` port — not a change to `sdram.sv` (still correct and relied on by the
narrow bridge) or to `tilemap_line_engine.sv`/`sprite_render_engine.sv` (still correct against
MAME's real format, and already independently unit-tested that way). Verified the fix is actually
load-bearing, not coincidental: temporarily bypassed the adapter in `tb_port2_sdram.sv` and
confirmed it reintroduces exactly the predicted scrambled-pixel failures, then restored it and
confirmed a clean pass. Also retrofitted into `tb_video_pipeline_sdram.sv`'s gfxrom wiring — a
no-op for that test's own pass/fail result (uniform data), but closes the gap so nobody copies the
"working but wrong" wiring pattern into real top-level integration later. **Any future top-level
integration wiring a gfx-ROM consumer to the real SDRAM controller needs this adapter** — general
16-bit-word/8-bit-byte ROM consumers (spritelut, `maincpu`, `audiocpu`) do NOT, and must not be
routed through it.

**Contention measurement** (`tb_port2_sdram.sv`, real `sprite_render_engine` rendering a single
16×16 sprite, correctness checked against the same reference formula as
`sim/sprite_render_engine_tb/tb_sprite_render_engine.sv`'s Case A): baseline `frame_done` latency
514 cycles; with synthetic `maincpu`+`audiocpu` continuous back-to-back traffic contending on the
same arbiter throughout, 736 cycles (~43% slower for this small case) — correctness held in both
cases, zero pixel mismatches. `maincpu` bridge round-trip latency under contention: min 15, max
41, avg 39 cycles (18 requests); `audiocpu`: min 29, max 41, avg 40 cycles (17 requests). `maincpu`
and `audiocpu` are synthetic continuous-pressure generators through `sdram_narrow_bridge` — neither
TG68K.C nor a req/valid sound-CPU wrapper exists yet (see ROADMAP.md), so this is a worst-case
bound, not a measurement of real CPU traffic shape. HPS download was deliberately left inactive
throughout (it doesn't overlap with gameplay in the real system — see `sdram_download.sv`'s
header); its absolute-priority behavior is covered separately by `tb_sdram_arbiter5.sv`'s Case 4.

`sdram_download.sv` (hps_io pulse → `sdram_arbiter5`'s held-`dl_req` contract) is a direct port of
the already-verified `ddram_download.sv` pattern, only the address width changed — not separately
unit-tested standalone, since its logic is identical to an already-tested module and its target
port's absolute-priority behavior is already covered by `tb_sdram_arbiter5.sv`.

## What carries over from the DDRAM work, and what doesn't

- `ddram_arbiter.sv`'s round-robin/hold-until-ack **design** is reused as-is for the two 2-way
  groups above (same req/valid consumer-facing contract every video engine already speaks) — only
  the thing it arbitrates onto changes (a burst-capable `sdram_phy` port instead of `ddram_phy`).
- `ddram_phy.sv` and `ddram_download.sv` are not deleted, but are no longer on the Phase 1
  critical path — `docs/phase1_ddram_map.md` now carries a header note to that effect.
- New RTL needed: the vendored/adapted burst-capable SDRAM controller itself (`rtl/memory/sdram/`,
  matching the `rtl/cpu/tg68k/`, `rtl/sound/jt10/` vendoring-with-PROVENANCE.md convention already
  used in this project), a `sdram_phy.sv` req/valid wrapper per physical port (translating the
  toggle-based `req`/`ack` into this project's req(hold)/valid(pulse) convention), and the two
  `sdram_arbiter` instances above.
