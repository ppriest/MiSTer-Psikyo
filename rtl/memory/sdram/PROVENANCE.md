# `sdram.sv` — provenance and modifications

**Upstream**: Sorgelig's `sdram.v` (Copyright (c) 2018 Sorgelig, GPL-3.0-or-later), fetched
2026-08-22 from `MiSTer-devel/Arcade-Jackal_MiSTer/rtl/ram_rom/sdram.sv` (raw.githubusercontent.com,
direct download, not paraphrased) and kept verbatim in this directory as
`sdram_upstream_reference.sv` for diffing against. This exact controller (or a close variant of
it) is vendored into dozens of MiSTer-devel arcade cores — a proven, widely-deployed reference,
not a one-off, matching this project's standing policy of reusing proven open components
(same posture as T80/`rtl/cpu/t80/`, jt10/`rtl/sound/jt10/`).

Targets the physical MiSTer SDRAM add-on board: an `MT48LC16M16` SDR SDRAM chip (16-bit data bus,
2 banks × 13-bit row × 9-bit column, 24-bit total word address = 32MB), reached via the DE10-nano's
`SDRAM_*` pins (`sys/emu_ports.vh`). 3 independent client ports, internally prioritized
port0→port1→port2 when idle, fixed low latency (no HPS/ARM-side contention, unlike `DDRAM_*`) —
see `docs/phase1_sdram_map.md` for why this project uses `SDRAM_*` rather than `DDRAM_*` for
real-time gfx/CPU ROM streaming.

## Why this isn't used verbatim

Every gfx ROM consumer already built in this project (`tilemap_line_engine`, `sprite_render_engine`)
speaks in 64-bit granules — one packed row of a 4bpp 16-pixel tile. The upstream reference's
read-side state machine captures exactly **one** 16-bit word per transaction, regardless of the
mode register's `BURST_LENGTH` field (confirmed by reading the state machine directly: `state ==
STATE_READY` fires a single `dout <= SDRAM_DQ`, with `STATE_READY` only one `CAS_LATENCY+1` cycles
after the read command — there's no logic to keep capturing further burst words). Using it as-is
for a 64-bit granule would mean 4 separate single-access transactions (~4×7=28 cycles minimum,
zero contention) — worse than the DDRAM path this pivot is replacing, not better.

## What changed, concretely

- `BURST_LENGTH` mode-register field: `3'd0` (single access) → `3'd2` (burst of 4). Writes are
  unaffected — `NO_WRITE_BURST=1'd1` (unchanged from upstream) keeps writes single-access always;
  the HPS ROM-download path writes one byte at a time regardless, no burst needed there.
- `dout`/`dout0`/`dout1`/`dout2` widened from `[15:0]` to `[63:0]`. `din`/`din0..2` stay `[15:0]`
  (write side unaffected, see above).
- `state` widened from `[2:0]` to `[3:0]`. `STATE_READ0` keeps upstream's own
  `STATE_CONT+CAS_LATENCY+1` margin (the `+1` matters — it's not padding, it's the one-cycle
  registration delay between a command's *decision* and its *bus-visible* effect, inherent to any
  synchronous FSM, not a testbench artifact; dropping it during initial development produced data
  systematically one cycle early/misaligned, caught by `tb_sdram.sv`, see git history), then
  `STATE_READ1`/`READ2`/`READ3` follow at `+1`/`+2`/`+3` more, with `STATE_LAST` now `STATE_READ3`
  instead of the upstream single-word `STATE_READY`.
- Read-capture logic replaced: instead of one `dout <= SDRAM_DQ` at `STATE_READY`, four captures
  across `STATE_READ0..STATE_READ3`, each latching `SDRAM_DQ` into the matching 16-bit lane of
  `dout[63:0]` (lane 0 = first word = the requested granule's lowest address, since
  `ACCESS_TYPE=1'd0` = sequential burst order, unchanged from upstream — the burst returns words in
  ascending address order starting from the column address programmed at the read command, exactly
  matching how `gfxrom_addr`'s 4 sequential 16-bit words are laid out in ROM). `ack`/`ram_req`
  clearing moved to the fourth (last) capture cycle. Write completion (`ack` on the single-word
  write path) also moved to this same last cycle for a uniform, single `STATE_LAST` across both
  read and write — writes finish a few cycles "late" relative to what a dedicated single-access
  write timing could achieve, but writes are the HPS download path only (not real-time-critical,
  see `docs/phase1_sdram_map.md`), so the simplicity of one shared completion point outweighs
  shaving a handful of cycles off a non-critical path.
- `SDRAM_CLK` generation: upstream drives it via an `altddio_out` megafunction instance (a
  phase-shifted DDR output). **Removed** — replaced with a plain `assign SDRAM_CLK = clk;` — for
  the same reason `ddram_phy.sv` keeps `DDRAM_CLK` a top-level concern: this module should
  simulate with a plain SystemVerilog toolchain, not require Altera's `altera_mf` simulation
  library compiled/mapped just to exercise the burst-4 read logic this module exists to verify.
  Real SDRAM_CLK phase generation is top-level integration work, tracked in `docs/ROADMAP.md`.
- No change to: initialization sequence (mode register load, precharge-all, refresh countdown),
  `RASCAS_DELAY`/`CAS_LATENCY` timing parameters (these are real MT48LC16M16 datasheet values,
  same chip, no reason to touch them), the auto-precharge column-address encoding (`A[10]=1`,
  unchanged — still correct with bursting: per the MT48LC16M16 datasheet, auto-precharge with a
  burst read defers the actual precharge until the full burst completes, so the "no persistent
  open-row state across ports" property this design depends on for safe 3-port interleaving is
  preserved unchanged), or the port-request priority/refresh-insertion logic.

## Syntax adaptations (behavior unchanged, `.v` → `.sv` compilation only)

Compiling upstream's plain-Verilog file under `vlog -sv` surfaced two real language-mode
differences, unrelated to the burst extension, fixed here:

- Upstream references `mode`/`reset`/`MODE_NORMAL` inside the "access manager" `always` block
  before their declarations appear later in the file — accepted under plain Verilog's looser
  forward-reference handling, rejected by `vlog -sv` ("Undefined variable"). Fixed by moving the
  `mode`/`reset` `reg` declarations and the `MODE_*` `localparam`s earlier in the file, before
  first use. No behavioral change.
- Upstream declares `SDRAM_DQ` as `inout reg [15:0]`, driven directly by procedural assignment
  (`SDRAM_DQ <= 'Z;`, `{..., SDRAM_DQ} <= {CMD_WRITE, data}`). `vlog -sv` rejects procedural
  assignment directly to an inout net ("Illegal reference to net"). Fixed with the standard SV
  pattern: `SDRAM_DQ` stays a plain `inout` net, driven by a continuous `assign SDRAM_DQ = dq_oe ?
  dq_out : 16'bz;`, with `dq_oe`/`dq_out` as the internal regs the state machine actually drives
  procedurally. Same tri-state behavior, same cycle the bus is driven or released.

- `state` and `ack0`/`ack1`/`ack2` given explicit `= 0` initializers (upstream leaves all four
  uninitialized, relying on Quartus's zero-power-up default for FPGA registers on real hardware —
  a divergence from plain ModelSim simulation, where an uninitialized `reg` starts as `X`, not
  `0`). Caught by the new testbench in two stages: first `mode` never reached `MODE_NORMAL`
  because `state == STATE_LAST` never compared true against `X`; after fixing `state`, every real
  transaction still silently failed because `req0 = ~ack0` propagates `X` forward forever when
  `ack0` starts as `X` (`~X` is `X`, and `ack0 != req0` with either operand `X` evaluates to `X`,
  which an `if` treats as false — so the controller's own "is there a pending request" check never
  fires). Both are purely simulation-fidelity fixes, same values real hardware powers up with.

- **Row/column address split swapped from upstream** — the real bug in this adaptation, found by
  `tb_sdram.sv`, not assumed correct because "it compiled." Upstream splits a 22-bit address as
  `row=a[13:1]` (low bits) / `col=a[22:14]` (high bits) — an arbitrary choice for a design that
  never bursts (`BURST_LENGTH=0` upstream, one word per transaction, no auto-increment to worry
  about). For a real burst-4 read, the SDR chip auto-increments its *column* counter across the
  burst — so 4 consecutive word addresses (one 64-bit gfx-ROM granule) need to land at 4
  consecutive *columns* of the *same row*, not 4 different rows at column 0. Kept upstream's split
  unchanged during initial development and got exactly that failure: lane 0 of a burst-4 read came
  back correct, lanes 1-3 came back `X` (silently reading from unrelated/unwritten rows 1, 2, 3 at
  column 0, not the intended granule). Fixed by swapping the split: `col=a[9:1]` (low bits),
  `row=a[22:10]` (high bits) — now the four low-order address bits that vary across one granule's
  four words select the column, matching what the chip's burst counter actually increments.

## What this does NOT cover yet

Burst-4 **write** support (not needed for Phase 1 — the only write consumer is the byte-at-a-time
HPS download path) and burst lengths other than exactly 4 (not needed — every gfx ROM granule in
this project is fixed at 64 bits / 4 words, see `docs/phase1_video_engine.md`'s tile row format).

## Verification

Not a black-box latency-stub testbench — `sim/sdram_tb/tb_sdram.sv` uses a behavioral MT48LC16M16
model (`sdram_chip_model.sv`) that decodes the real `{SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}` command
encoding (ACTIVE/READ/WRITE/PRECHARGE/AUTO_REFRESH/LOAD_MODE) and drives `SDRAM_DQ` with real
CAS-latency and burst-sequencing timing, so a wiring bug in either the burst extension above or
the surrounding req/ack contract would show up as a real protocol violation (e.g. driving
`SDRAM_DQ` while the chip model is also driving it, or reading before CAS latency has elapsed),
not just wrong data.

## Quartus-only synthesis fix: `rfs_cnt`/`rfs`/`rfs2`/`init_old` moved to module level

Found running a real `quartus_map` pass on the full `Psikyo.sv` build (docs/ROADMAP.md's
top-level integration work) — never caught by any ModelSim simulation, since ModelSim accepts
the construct that broke this. Three registers (`rfs_cnt`, `rfs`, `rfs2` in the access-manager
`always` block) were declared as plain block-local `reg`s inside their own `always
@(posedge clk)` block, and a fourth (`init_old`, initialization block) as `static reg
init_old=0;` — upstream's own existing pattern, inherited here, not added by this project.
Quartus 17.0's SystemVerilog elaborator rejects non-blocking assignments to *either* form
outright: `Error (10959): illegal assignment - automatic variables can't have non-blocking
assignments`. `static` is not a working fix for this Quartus version (tried it on `rfs_cnt`/
`rfs`/`rfs2` first — same error, just relocated). The actual fix: move all four to module-level
`reg` declarations (unambiguously static, like every other register in this file), given the
same explicit `= 0` initializers as `state`/`ack0..2`/`active`/`ram_req` already have, for the
same simulation-fidelity reason (real hardware zero-powers-up these registers; ModelSim leaves
a never-explicitly-initialized `reg` as `X`, and `rfs_cnt`'s own `rfs_cnt <= rfs_cnt + 1` would
never escape `X` once it started there — not confirmed load-bearing for any specific observed
bug, refresh timing hasn't been the subject of a dedicated test, but zero-risk and consistent
with the rest of this file). Purely a declaration-scope change, no behavioral difference:
re-verified `sim/sdram_tb/tb_sdram.sv` (all 6 cases, including the two added investigating a
separate, unrelated bug — see docs/ROADMAP.md) and `sim/psikyo_sdram_top_tb/`,
`sim/psikyo_top_tb/`'s full suite all still pass. With this fix, `Psikyo.sv`'s entire RTL chain
(this file included) synthesizes cleanly under real Quartus 17.0 `quartus_map` — 0 errors, 22382
logic cells, 1349 RAM segments, 3 PLLs, 39 DSP elements, no warnings anywhere in `Psikyo.sv`,
`rtl/psikyo_top.sv`, or this file.
