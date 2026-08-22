# Psikyo (PS1/PS2) MiSTer Core — Roadmap

## Context

Goal: a DE10-nano MiSTer core for the original Psikyo shooter hardware emulated by MAME's
`psikyo.cpp` / `psikyo_v.cpp` (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road, Strikers 1945,
Tengai — the genuine PCB sets; bootleg boards are explicitly out of scope, see below) — a Quartus
17.x Verilog/SystemVerilog project producing one `.rbf` and a `.mra` per supported game, reusing
proven open MiSTer components where they exist and building custom RTL for the two Psikyo-specific
video ASICs (tilemap + zoom-sprite engine) that have no existing FPGA implementation anywhere.

This doc is the outcome of reading the full `psikyo.cpp`/`psikyo_v.cpp` driver and surveying the
MiSTer-devel/jotego/atrac17 ecosystems for reusable IP. It is a **roadmap document**, not RTL —
per your direction, actual Verilog/Quartus work starts in a dedicated follow-up session once
Phase 0 is scoped. Decisions below reflect your answers: narrow game scope first (and, per your
follow-up, drop the bootleg boards entirely — they're variant hardware that would only add
complexity without adding real coverage), commit to TG68K.C for the CPU, simulate the PIC
protection (matching MAME) with a real YMF278B core.

## Progress (kept current — last updated 2026-08-22, commit `4f48e23`)

**Phase 0 — CPU spike: complete.** TG68K.C vendored, boots and executes 68020-mode code
correctly in ModelSim (including 68020-only opcodes: MULU.L, DIVU.L, scaled-index addressing,
BFEXTU), and synthesizes/fits cleanly on the real Cyclone V (2,788/41,910 ALMs). See
`rtl/cpu/tg68k/PROVENANCE.md` for the debugging notes (two false-alarm "core bugs" that were
actually testbench mistakes, documented so they aren't re-investigated).

**Phase 1 — SH201B/KA302C hardware: in progress**, on branch `phase1-sh201b-ka302c`.

- Memory map documented (`docs/phase1_memory_map.md`) — shared `psikyo_map`, sprite/palette/
  tilemap VRAM layout, sound CPU maps including gunbird's non-power-of-two bank window.
- Video engine design documented (`docs/phase1_video_engine.md`), iteratively extended as each
  piece gets built — this is the working spec the RTL below is implemented against.
- **Tilemap engine**: combinational stages (`tilemap_addrgen`, `tile_row_decode`,
  `tilemap_coord`, `tile_cell_decode`) and the sequential scanline sequencer
  (`tilemap_line_engine.sv`, one instance per layer) all built and verified. This is the first
  complete vertical slice of the video pipeline (VRAM → pixel stream).
- **Sprite engine: RTL complete.** Architecture documented (`docs/phase1_video_engine.md`,
  "Sprite frame renderer: architecture") — unlike the tilemap engine's just-in-time per-scanline
  approach, sprites render into a full double-buffered 320×224 frame buffer once per frame,
  decoupled from pixel-clock timing, because inter-sprite overlap resolution and the display
  list's size make a real-time per-scanline walk impractical. Every module built and verified:
  `sprite_zoom_lut`, `sprite_record_decode`, `sprite_pos_transform`, `sprite_subtile_step`,
  `sprite_zoom_src_index` (combinational front end); `sprite_display_list_walker`
  (flow-controlled display-list walk, mod-768 index folding, 0xFFFF termination) and
  `sprite_record_fetch` (per-sprite attribute fetch); `sprite_render_engine`
  (`docs/phase1_video_engine.md`, "Sprite render engine: pipeline design") — the top-level FSM
  chaining all of the above into the full per-sprite pipeline (display-list walk → attribute
  fetch → per-subtile position → spritelut ROM → per-row gfx ROM fetch → per-column pixel
  write), with screen clipping and live transparent-pen handling, integration-tested against 4
  cases (basic placement, flip_x pixel mirroring, multi-tile flip grid ordering, transparent
  pen) with independently-latencied ROM models to rule out timing-dependent bugs; and
  `sprite_frame_buffer` — the double-buffered 320×224 memory behind the render engine's write
  port, with a combined swap+clear action (`frame_swap`) so a caller can't forget to clear the
  newly-selected render bank before writing into it, and a read port for the compositor.
  End-to-end tested (swap/clear → write → swap → readback, confirming untouched pixels correctly
  read as absent). Nothing structural left to build in the sprite pipeline itself — remaining
  work is wiring it into the rest of the core.
- **Compositor: built and verified** (`compositor.sv`) — combines the two live tilemap-layer
  pixel streams with `sprite_frame_buffer`'s output into a resolved palette index and xRGB_555
  RGB, per the priority-mask table and per-layer transparent-pen logic derived in
  `docs/phase1_video_engine.md` ("Compositor: backdrop, transparent-pen, and palette lookup") —
  including reproducing a real MAME quirk where the backdrop color always follows layer 0's
  transparent-pen bit regardless of which layer is actually enabled (dead fallback code in the
  driver itself). Entirely combinational, no clock. 12-case testbench PASS, including the subtle
  priority-mask edge case where a "behind"-priority sprite still shows through when neither
  tilemap layer drew anything.
- Real Psikyo MAME ROM zips (`roms/`, gitignored — never commit ROM dumps, see the legal note
  below) are now available locally for samuraia/gunbird/btlkroad/s1945/tengai — fully-merged
  MAME romsets (all game code, sound, and gfx ROMs in one zip per game, not split parent/clone
  sets). Useful both for eventual `.mra`/ROM-loader work and, sooner, for pulling real gfx ROM
  content into simulation testbenches instead of synthetic test patterns.
  **Legal note**: these ROMs are not, and never will be, committed to this repo, and are not
  distributed by this project in any form. Anyone running this core is responsible for either
  dumping ROMs from hardware they own or otherwise holding appropriate legal rights to them —
  documented in [`Readme.md`](../Readme.md) as the low-risk default for this project.
- **Sound subsystem: started.** T80 (Z80, `rtl/cpu/t80/`) and jt10 (YM2610, `rtl/sound/jt10/`)
  vendored, licenses/provenance documented (T80: BSD-style, low risk — it's the de facto
  standard MiSTer-devel Z80 core, not a single-option risk like TG68K.C. jt10: GPL-3.0, a real
  copyleft posture worth having noted explicitly rather than glossed over). T80 boot-spike
  verified (`sim/t80_spike/`) — resets, fetches from address 0, executes opcode fetch/immediate
  fetch/memory write/I/O write/HALT correctly, matching the classic Z80 bus protocol this
  project's memory-map wiring depends on. jt10 is vendored but **deliberately not yet
  verified** — FM synthesis correctness needs real audio-domain verification (e.g. VGM playback
  comparison), a much bigger undertaking than a boot spike, tracked honestly as not-done rather
  than claimed on a token compile check. Confirmed directly from `psikyo.cpp`'s ROM_START blocks
  that jt10's ADPCM-A/B ROM interfaces are load-bearing for Phase 1 (sngkace: ADPCM-A;
  gunbird: ADPCM-A+B), not optional — sound-side SDRAM/ROM banking will need to cover them.
  `sound_cpu_sngkace.sv` wires T80se up against sngkace's actual sound CPU memory/IO map
  (fixed/RAM/banked ROM regions, bank register, sound-latch/NMI handshake), with the bank's
  physical-ROM mapping confirmed from source (`sound_bankswitch_w<0>`) rather than assumed. YM
  I/O is exposed as an external chip-select bus, not yet wired to jt10 (same "prove the trusted
  piece before the risky one" ordering as T80-before-jt10). The real open question here —
  generating correct WAIT_n for T80 against this project's synchronous 1-cycle ROM/RAM — was
  worked out from a real reference (NeoGeo_MiSTer's Z80 wiring) and then verified empirically in
  simulation rather than trusted from derivation alone; both test scenarios (straight-line
  ROM/RAM/bank exercise, and a dedicated NMI-handshake scenario) PASS.
  `sound_cpu_gunbird.sv` is the gunbird/btlkroad variant (confirmed via the `GAME()` driver
  table that Battle K-Road shares gunbird's exact machine config/sound map, so one module covers
  both) — different RAM size/location (512B at 0x8000-0x81FF vs sngkace's 2KB at
  0x7800-0x7FFF), different I/O port layout (bank select at 0x00, YM2610 at 0x04-0x07), and a
  different bank-select shift (`(data>>4)&0x03` vs sngkace's `data&0x03`). Its banked window
  (0x8200-0xFFFF, 0x7E00 bytes — not a power of two) turns out to collapse to the exact same
  clean `{bank, addr[14:0]}` concatenation sngkace uses, confirmed algebraically against the
  real `m_audiobank->configure_entries(0, 4, base+0x200, 0x8000)` call rather than assumed —
  documented in the module header. Same two-scenario testbench structure as sngkace's, with the
  banked read deliberately targeting the window's first address (0x8200) to confirm the
  boundary math holds exactly at the edge; both scenarios PASS.
- **`.mra` files: done for all four Phase 1 parent games plus every MAME clone set**
  (`releases/`, clones under `releases/_alternatives/`) — built directly from each game's
  `ROM_START`/`INPUT_PORTS_START` blocks in `psikyo.cpp` (region names, file sizes, offsets,
  CRC32s, and real per-game DIP differences — e.g. btlkroad repurposes gunbird's Lives/Bonus
  Life DSW bits for Blood Effects/Handicap/Debug instead, confirmed from source rather than
  assumed additive). Built out of roadmap order at your direction (skipped ahead of the sound
  subsystem/SDRAM items below).

  **Parent sets** (top level of `releases/`, one per MAME `GAME()` parent — confirmed against
  the driver table, not assumed from title similarity): Samurai Aces (World) `samuraia`,
  Gunbird (World) `gunbird`, Battle K-Road `btlkroad`.

  **Clone sets** (`releases/_alternatives/`, matching the convention seen in other MiSTer
  arcade release repos e.g. rmonic79/Arcade-Raiden_MiSTer): Sengoku Ace (Japan, set 1)
  `sngkace`, Sengoku Ace (Japan, set 2) `sngkacea`, Samurai Aces (Korea?) `samuraiak` — all
  three clones of `samuraia`, confirmed via the `GAME()` table (sngkace was initially placed
  at the top level by mistake, since it's a genuinely different program ROM rather than a
  region-DIP variant — caught on review and moved); Gunbird (Japan) `gunbirdj`, Gunbird
  (Korea) `gunbirdk` — clones of `gunbird`, sharing a Region-less input port block distinct
  from the parent's; Battle K-Road (Korea) `btlkroadk` — clone of `btlkroad`, same DIP layout
  but a different Region default (Korea vs. the parent's Japan). Several clones have real ROM
  differences beyond just program content worth remembering: samuraiak and gunbirdk both have
  double-size maincpu ROMs (0x100000 vs. 0x80000) vs. their parents.

  Two things are explicitly provisional and flagged as such in every file: the ROM region
  concatenation order is this project's own SDRAM-blob layout choice (not yet consumed by any
  RTL, since SDRAM integration doesn't exist yet — may change once it does), and the DIP
  `<dip bits="...">` status-bit positions are a placeholder scheme (game DIPs starting at
  status bit 16) not yet verified against real core `.sv` `status[]` wiring, for the same
  reason.
- **DDRAM integration: started.** Design doc `docs/phase1_ddram_map.md` covers the real
  MiSTer `DDRAM_*` protocol (verified against a working reference core,
  MiSTer-devel/TSConf_MiSTer's `ddram.sv`, not derived from memory) and this project's fixed
  address map (one flat layout shared by every Phase 1 game, sized off the largest real
  content across all parent *and* clone sets — differs from, and will eventually replace, the
  tightly-packed per-game layout the `.mra` files currently use, which every one of them
  already flags as provisional). Confirms directly against the built RTL that
  `tilemap_line_engine`/`sprite_render_engine`'s gfxrom/spritelut ports are already req/valid
  latency-agnostic (no redesign needed); `sound_cpu_sngkace`/`gunbird`'s ROM ports were NOT at
  the time this was written (flagged as an open item) but have since been converted too — see
  the "sound-CPU ROM ports converted to req/valid" entry above.
  `rtl/memory/ddram_phy.sv` — the single-port req/valid wrapper around the real `DDRAM_*`
  handshake — is built and verified (`sim/ddram_phy_tb/`, two independently-parameterized
  read-latency models, 6 and 13 cycles, to rule out latency-dependent bugs). Two real bugs
  found and fixed: an RTL gating bug (`DDRAM_RD`/`DDRAM_WE` not gated by `!DDRAM_BUSY` in the
  combinational assign, caught via review before simulating) and a genuine testbench race
  (`while (busy) @(posedge clk)` checked on the same simulation time step as the edge that
  might update `busy`, an NBA race that manifested as an apparent total deadlock rather than
  an obvious mismatch — documented in the testbench header as a lesson for future testbenches
  in this project).
  `rtl/memory/ddram_arbiter.sv` routes the four already-req/valid ports (tilemap layer 0/1
  gfxrom, sprite gfxrom, sprite spritelut) plus an HPS download-write port onto that one
  `ddram_phy` port — rotating-pointer round robin among the four read consumers (fairness:
  whoever's served rotates to the back), download always wins immediately (only active
  pre-gameplay). Verified as a real integration test (actual `ddram_phy`+`ddram_model`, not
  stand-ins) across 4 cases including a real round-robin-fairness check (not just "does it
  work with one consumer"). Real bug found via the testbench: an early version treated every
  request port as a one-shot pulse, but checking directly against `sprite_render_engine.sv`
  showed `gfxrom_req`/`lut_req` are actually HELD until their `valid` pulse — a one-shot
  request arriving while the arbiter is busy elsewhere is silently lost. Fixed by making every
  request port (including the download path) a hold-until-acknowledged contract, documented
  explicitly in the module header, including what it implies for the not-yet-built HPS
  `ioctl_download` wrapper (likely needs `ioctl_wait` backpressure to translate hps_io's real
  one-shot `ioctl_wr` into this convention). Not yet built: the HPS-facing wrapper itself, and
  converting the sound CPU wrappers' ROM ports to req/valid so they can join this arbiter too.

  **Resolved: sound-CPU ROM ports converted to req/valid**, both `sound_cpu_sngkace.sv` and
  `sound_cpu_gunbird.sv`. A first attempt (see git history) hit a real, reproducible bug —
  against a req/valid ROM model with 5-cycle latency, `LD A,(0x8000)` (a 3-byte opcode whose own
  memory-read M-cycle follows two operand-fetch M-cycles) corrupted the accumulator, with no
  memory access to `0x8000` visible anywhere in the trace — and was reverted rather than land a
  known-broken change, with the note that a proper T80-internal T-state waveform trace was
  needed, not more blind top-level signal-log reading.

  This second attempt was designed directly from `T80.vhd`/`T80se.vhd`'s actual RTL (read, not
  re-derived from memory or guessed): `T80.vhd`'s state machine freezes `TState` at 2 for as long
  as `WAIT_n` reads 0 (resampled every cycle, no separate edge logic); `T80se.vhd` captures
  `DI_Reg <= DI` on the exact edge `TState=2 and WAIT_n=1` is first true; and — the key fact the
  first attempt's "race in back-to-back M-cycles" suspicion didn't have — `RD_n`/`MREQ_n` are
  registered outputs that default to `1` every cycle and are only pulled low by a matching
  `TState` condition, so there IS always a real one-cycle gap (T3) between the end of one read
  M-cycle and the start of the next, even within one multi-byte instruction. Given that gap is
  real, the new design ties ROM-read `WAIT_n` to a plain combinational level
  (`is_rom_read = mem_active_rd && !is_ram`, glitch-free by construction since `mreq_n`/`rd_n`
  can't toggle mid-M-cycle) combined with a level-tracked `rom_pending` flag (set when a fresh
  `is_rom_read` window opens, cleared on `rom_valid`) — structurally unable to miss a transition
  the way a same-cycle edge-detector can. RAM/I/O/writes keep the original fixed one-wait-cycle
  scheme unchanged, explicitly scoped out via `!is_rom_read`, so nothing about their
  already-verified behavior was touched.

  **Confirmed, not just re-derived**: re-ran the exact same `LD A,(0x8000)` (sngkace) and
  `LD A,(0x8200)` (gunbird, its own equivalent case, already present in that testbench) scenarios
  against a real 5-cycle-latency req/valid ROM model, with real T80-internal M-cycle/T-state
  tracing (hierarchical reference into `u_cpu.u0`'s `MCycle`/`TState`, the actual signals
  `T80se.vhd`'s architecture exposes — not reconstructed from external bus signals). Both games'
  traces show all 4 M-cycles of the instruction (3 fetch + 1 banked read) with exactly one clean
  `rom_req` pulse each, `wait_n` dropping and returning at the right edges, and the correct byte
  (`0xC3`/`0xC7`) landing in the accumulator — this is the actual "T80-internal T-state waveform
  trace" the first attempt's revert note flagged as necessary. Both testbenches PASS in full
  (address decode, banking, RAM, sound-latch/NMI handshake, and the ROM port).

  `rtl/memory/ddram_download.sv` bridges hps_io's real ROM-download interface (checked
  directly against `sys/hps_io.sv`'s port list — `ioctl_download`/`ioctl_index`/`ioctl_wr`/
  `ioctl_addr`/`ioctl_dout`/`ioctl_wait`) into `ddram_arbiter`'s hold-until-acknowledged
  `dl_req` contract, closing the gap flagged when the arbiter was built. Confirmed from source
  that hps_io itself doesn't interpret `ioctl_wait` at all — it's wired straight to `HPS_BUS`
  and enforced on the HPS/Linux side with real round-trip latency, so this module holds
  `ioctl_wait` continuously (not a same-cycle handshake) from accepting a byte until ready for
  the next, the standard safe pattern. Only `ioctl_index==0` is accepted (the only rom index
  any of the nine `.mra` files use). Verified as a real integration test (chained through the
  actual arbiter/phy/model, with a test-side sender that genuinely respects `ioctl_wait`
  pacing) across 3 cases. **This closes out the DDRAM transport-layer work** (`ddram_phy` →
  `ddram_arbiter` → `ddram_download`, all built and verified) — what's left is instantiating
  this stack in the actual top-level `emu.sv`/core module alongside the video/sound engines
  and TG68K.C, which is top-level integration work, not more transport-layer RTL.
- **DDRAM → SDRAM pivot.** After confirming the DDRAM throughput failure below with
  `tb_video_pipeline_ddram.sv`, researched the right fix rather than immediately patching the
  arbiter, and found the DDRAM transport itself was the wrong backend for this traffic — not
  something to patch, something to replace. Full evidence trail and the active design now live in
  `docs/phase1_sdram_map.md`; short version: MiSTer's own developer docs describe `DDRAM_*` as for
  "non-critical time purposes" with latency that "can be way longer" than the typical ~20
  cycles (unbounded worst case, not just high average case — a real problem for a hard per-tile
  fetch budget no matter how the average-case cycle math comes out), recommend `SDRAM_*` for
  lower, bounded latency, and cite real graphics cores doing exactly that; a real reference
  controller (Sorgelig's `sdram.sv`, vendored into dozens of MiSTer-devel arcade cores including
  `Arcade-Jackal_MiSTer`, fetched and read directly) gives 3 independent ports at a fixed ~6-7
  cycles; and this project's own original roadmap ("Component reuse map", written before any RTL
  existed) already specified `SDRAM ctrl` and "SDRAM tile/sprite ROM banking" for Phase 1 — this
  session's DDRAM stack was itself the deviation, now being corrected back, not a new direction.
  Also found and recorded honestly (not hidden to make the DDRAM number look worse than it is):
  the failing test's specific "26 cycles > 16-cycle budget" number is partly a testbench-fidelity
  artifact (`ce_pix` tied to `1'b1`, i.e. system clock == pixel clock 1:1, unlike a real
  Template_MiSTer-style core that runs `clk_sys` far faster and gates pixel-domain logic with a
  real `ce_pix` divider) — doesn't change the pivot decision (the unbounded-worst-case argument
  above is independent of that number), but is tracked as a real testbench gap to fix regardless
  (see "Next steps").
  `ddram_phy`/`ddram_arbiter`/`ddram_download` are not deleted — the request/ack round-robin
  arbiter design they proved out is reused directly for the new SDRAM arbiters — but they're off
  the Phase 1 critical path; `docs/phase1_ddram_map.md` carries a header note to that effect.
  Genuine new RTL still needed, not a copy-paste: `docs/phase1_sdram_map.md`'s "The 64-bit granule
  problem" — Sorgelig's reference controller has no burst support (single 16-bit word per
  transaction, confirmed by reading the read-side FSM directly, not assumed), so fetching a
  64-bit tile-row granule needs a real burst-4-read extension to the controller, verified against
  a behavioral SDR chip model that actually decodes `nRAS`/`nCAS`/`nWE`/`SDRAM_A` command
  sequencing rather than a black-box latency stub.

  **Burst-4 controller: built and verified.** `rtl/memory/sdram/sdram.sv` (`PROVENANCE.md` in the
  same directory documents every change from the vendored upstream reference in detail) — mode
  register burst length set to 4, `dout` widened to 64 bits, four-cycle read-capture sequence
  replacing the single-word capture. `sim/sdram_tb/tb_sdram.sv` + `sim/sdram_tb/sdram_chip_model.sv`
  (a real command-decoding behavioral MT48LC16M16 model, not a latency stub) cover burst-4 read
  assembly, byte-lane write masking, two simultaneous ports, and a latency-bound sanity check — 4/4
  PASS. Real bugs found and fixed along the way, not just syntax porting: (1) the row/column
  address split had to be **swapped** from upstream's `row=low-bits/col=high-bits` — upstream never
  bursts, so the split was arbitrary there, but a hardware burst auto-increments the *column*, so
  four consecutive word addresses (one granule) must land at four consecutive columns of the *same*
  row, not four different rows — caught when three of four burst lanes came back reading unrelated,
  unwritten memory; (2) the chip model initially ignored the `DQML`/`DQMH` byte-lane write mask
  entirely (always wrote the full 16 bits), caught by the byte-masking test case clobbering the
  untouched byte lane instead of preserving it; (3) a genuine off-by-one in the burst-read CAS
  timing (dropped upstream's own `+1` registration-delay margin when computing the first
  read-capture cycle), caught by the first burst word capturing high-impedance garbage instead of
  real data. Also fixed, unrelated to the burst logic: two real Verilog-to-SystemVerilog
  compilation-mode differences (forward-referenced `mode`/`reset`/`MODE_NORMAL` before their
  declarations, and procedural assignment directly to an `inout` net) and two simulation-fidelity
  gaps (uninitialized `state`/`ack0..2` registers reading `X` in ModelSim instead of the `0` real
  hardware powers up with, silently wedging the whole state machine) — all documented in
  `PROVENANCE.md`. `sdram_phy.sv` (req/valid wrapper for one physical port) and
  `sdram_arbiter2.sv` (2-way round-robin, same hold-until-ack design as `ddram_arbiter`) are
  also built.

  **Direct measurement, not just design intent**: `sim/video_pipeline_tb/tb_video_pipeline_sdram.sv`
  re-runs the exact dual-tilemap-layer scenario `tb_video_pipeline_ddram.sv` confirmed failing
  (954/954 mismatches, 100%) against the real SDRAM stack. First attempt (both layers sharing one
  arbitrated port, matching the port-grouping table as first drafted): 370/954 (39%) — a large
  real improvement, not a full fix. Root cause: that grouping put the two consumers *proven* to
  contend simultaneously onto the same port. Rewired to give each layer its own dedicated
  physical port (no arbiter at all between them — `docs/phase1_sdram_map.md`'s port-grouping
  table revised accordingly): 189/954 (20%) — real, but still not a full fix.

  **Residual 20% root-caused and fixed, not just measured.** "Dedicated ports" only separates
  the address/data *buses* — `sdram.sv`'s read-capture pipeline (`state`/`dout`/`ram_req`) is a
  single shared resource across all 3 logical ports (one physical chip, one data bus). Since
  both tilemap layers run off identical `line_start`/`h_active` timing, they request in
  near-lockstep; instrumenting layer 1's real per-tile `gfxrom_req`→`gfxrom_valid` latency showed
  a bimodal split — ~15 cycles nominal (fits the 16-cycle budget), but ~22 or ~35 cycles on
  roughly 1-in-5 tiles when layer 0's simultaneous request won arbitration. With only 1 tile ever
  banked ahead of display, each such stall was an immediate miss (1-in-5 ≈ the measured 20%).
  Fix: widened `tilemap_line_engine`'s prefetch from a fixed 2-entry ping-pong to a parameterized
  `PREFETCH_DEPTH`-entry ring buffer (module interface unchanged, `fetch_target`/`display_sel`
  generalized from a toggle bit to a modulo-N pointer); `PREFETCH_DEPTH=8` gives enough
  absorption to ride out these stalls. **Confirmed clean: 0/12720 mismatches over 40 sustained
  lines** (widened from the original 3-line check specifically to give the stall many chances to
  recur) — re-verified against every existing consumer of `tilemap_line_engine`
  (`tilemap_line_engine_tb`, `tb_video_pipeline`, `tb_video_pipeline_compositor`), no regressions.
  This is a real fix for the exact contention pattern tested, not a formal guarantee against every
  possible contention pattern — the single-shared-pipeline constraint is real hardware (one SDR
  SDRAM chip), and a deeper buffer works around it rather than removing it; a genuinely faster,
  independently-clocked fetch domain (real CDC) or a pipelined/overlapping SDRAM controller
  remain the architecturally "correct" long-term fix, tracked as a known limitation, not urgent.

  Also found and recorded as a genuine, useful negative result along the way: tried a realistic
  ~1-in-14 `ce_pix` divider (matching a real `clk_sys`/pixel-clock ratio) instead of `1'b1`, and
  it made things dramatically worse (12426/13356) because `tilemap_line_engine` has no `ce_pix`
  input — it's a single-clock-domain design (`clk` == pixel clock throughout), not a
  fast-clock-plus-`ce_pix` one. `ce_pix=1'b1` in these testbenches is therefore the *correct*
  model of the current RTL, not a simplification — see `docs/phase1_sdram_map.md`'s "Verification
  results" for the full writeup.
- **Port 2 (sprite gfxrom + spritelut + maincpu + audiocpu + download): built and measured.**
  `sdram_arbiter5.sv` (5-way, direct reuse of `ddram_arbiter`'s design) and
  `sdram_narrow_bridge.sv` (new: extracts a 16-bit word or 8-bit byte from `sdram.sv`'s 64-bit
  granule, needed since only sprite gfxrom is naturally granule-shaped — spritelut/maincpu/
  audiocpu are narrower) are both built and verified against the real SDRAM transport, not stubs
  (`sim/sdram_arbiter5_tb/`, `sim/sdram_narrow_bridge_tb/`).

  **Real bug found and fixed, not just measured: gfx ROM byte order.** Wiring the real
  `sprite_render_engine` through this stack with genuinely non-uniform gfx ROM content
  (`sim/port2_sdram_tb/tb_port2_sdram.sv`) immediately failed with scrambled pixels.
  `sdram.sv`'s burst-4 capture packs bytes in ordinary ascending-address order (confirmed against
  `tb_sdram.sv`'s own passing test), but `tilemap_line_engine.sv`/`sprite_render_engine.sv` both
  assume the opposite (MAME's MSB-first `gfx_16x16x4_packed_msb` format, correct and already
  unit-tested against synthetic ROM models using that same convention) — neither side was wrong
  on its own, the mismatch was only at the untested seam between them. Every prior SDRAM video
  test (`tb_video_pipeline_sdram.sv`) used uniform all-zero ROM content, which is
  byte-order-invariant, so this never showed up before. Fixed with a new adapter,
  `rtl/memory/gfxrom_byte_reorder.sv`, inserted at the `sdram.sv`-to-gfxrom-consumer seam (NOT a
  change to `sdram.sv`, which is still correct and relied on as-is by `sdram_narrow_bridge.sv`'s
  ordinary little-endian word/byte consumers) — confirmed load-bearing by temporarily bypassing
  it and reproducing the exact predicted scrambled-pixel failures, then restoring it. Retrofitted
  into `tb_video_pipeline_sdram.sv` too (a no-op there given uniform data, but closes a real
  coverage gap so the wrong-but-passing wiring pattern doesn't get copied into real top-level
  integration). See `docs/phase1_sdram_map.md`'s "Port 2: built and measured" for the full writeup.

  **Contention measurement**: one real 16×16 sprite through the full stack — baseline
  `frame_done` 514 cycles, with synthetic continuous-pressure `maincpu`+`audiocpu` traffic
  contending on the same arbiter throughout, 736 cycles (~43% slower), correctness unaffected in
  both cases (0 pixel mismatches). `maincpu`/`audiocpu` are synthetic (no real CPU wrapper RTL
  exists yet, see "Next steps" below) but modeled as worst-case continuous back-to-back requests,
  same reasoning as the tilemap contention test. HPS download deliberately left inactive
  (doesn't overlap real gameplay); its absolute-priority behavior is covered separately.
- **Top-level integration: started.** `rtl/video/video_timing.sv` — the raw H/V timing
  generator — is built and verified: hcnt/vcnt raster counters, h_active/v_active/hblank/
  vblank, hsync/vsync, and the `line_start`/`frame_start` pulses the video engines and
  `sprite_frame_buffer`'s swap trigger need, matching the exact screen config confirmed from
  `psikyo.cpp`'s `set_raw(14.318181_MHz_XTAL/2, 456, 0, 320, 262, 0, 224)` (not assumed).
  hsync/vsync pulse width/position are explicitly flagged as this project's own RTL-level
  design choice, since MAME's `set_raw()` only specifies blanking boundaries, not real sync
  timing (it doesn't drive an analog CRT) — not claimed to match the original PCB. Verified
  across 7 cases including a full two-frame walk. Not yet done: instantiating this alongside
  the DDRAM stack, video/sound engines, and TG68K.C in the actual top-level `emu.sv`/core
  module, the CRT_Offset module, DIP/control mapping, and hiscore.v (later-stage) — this is
  also where the `.mra` files' DIP status-bit positions get finalized/verified against real
  RTL for the first time (the ROM-layout half of that is already done — see next item).

  **Real integration test, plus a real (smaller) bug found and fixed**: wired `video_timing`
  into a real `tilemap_line_engine` instance for the first time (`sim/video_pipeline_tb/`) —
  confirmed the two modules' hcnt/vcnt/h_active/line_start conventions genuinely agree
  (cross-checked against `docs/phase1_video_engine.md`'s own stated contract beforehand).
  First attempt at this test reported an apparent sustained-operation `fetch_overrun`
  starting around active line 2-3, initially written up here as an unresolved open item — that
  turned out to be a **false alarm from the test's own methodology**, not a real problem:
  `fetch_overrun` is sticky, and the very first active line after any reset is an unavoidable
  cold-start case (`video_timing`'s reset always lands mid-active-line, no prior hblank to
  prefetch in) — once that expected, understood cold start latches the sticky bit, it's
  permanently indistinguishable from "a real overrun happened later" no matter how carefully
  reset timing is arranged afterward (confirmed by direct experimentation — several
  reset-sequencing approaches were tried, none worked, since the underlying condition is
  genuinely met at that moment regardless of when reset releases). Fixed by not checking the
  DUT's sticky output at all — independently replicating its own trigger condition
  (`h_active && !buf_ready[display_sel]`) via hierarchical access instead, giving a true,
  non-sticky per-cycle reading. With that fix, the test **genuinely PASSes**: detailed
  cycle-by-cycle tracing across multiple lines showed completely healthy, steady-state
  fetch/display interaction throughout — sustained multi-line/full-frame operation is
  confirmed clean.

  A real, independent, smaller bug WAS found and fixed along the way in
  `tilemap_line_engine.sv`: the fetch FSM only acted on `line_start` from `S_IDLE`, inside
  the state case statement — since the fetch FSM's last tile for a line can legitimately
  still be in flight when the next line's `line_start` arrives (no structural guarantee fetch
  always finishes strictly before display needs it), that pulse could be silently dropped
  whenever the FSM wasn't already idle, permanently desyncing fetch from display for the rest
  of the frame. Fixed by checking `line_start` before the state case, top priority in any
  state (a new line always outranks finishing stale work for the old one). Re-verified against
  `tilemap_line_engine`'s own pre-existing single-line testbench — still PASSes unchanged.
  `tilemap_line_engine` can now be treated as verified for sustained real gameplay, not just
  the narrower single-line scenario its original testbench covered.

  **Extended one stage further**: `sim/video_pipeline_tb/tb_video_pipeline_compositor.sv`
  wires `video_timing` driving BOTH tilemap layers into a real `compositor` instance
  (sprites still tied off — that needs the DDRAM stack, a separate step). Distinct VRAM
  content per layer makes the composited output distinguishable, letting the test verify
  real compositor priority end-to-end (layer 1 wins when both draw; disabling layer 1
  mid-stream correctly hands off to layer 0, proving it was genuinely live, not just unused
  wiring). One real, understood pipeline-startup artifact found and excluded (not a bug):
  `pixel_valid`'s registered one-cycle-ish latency from `h_active` means the first pixel or
  two of every line legitimately sees neither layer valid yet and falls back to backdrop —
  found via the test itself, excluded with a documented reason, not silently loosened.

  **Extended once more, onto the real DDRAM transport** —
  `sim/video_pipeline_tb/tb_video_pipeline_ddram.sv` routes both tilemap layers' gfxrom ports
  through the actual `ddram_arbiter`/`ddram_phy` (not synthetic per-layer models) under
  sustained operation. **This one genuinely fails, and correctly so** — not a false alarm this
  time, but the first concrete confirmation of `docs/phase1_ddram_map.md`'s already-documented
  "Known open item: throughput, not just correctness": with a realistic 10-cycle DDR model
  latency, two consumers requesting a tile simultaneously (which the two tilemap layers
  routinely do) forces the arbiter to fully serialize them, ~26 combined cycles against each
  layer's 16-cycle-per-tile budget. Confirmed via tracing that this is the exact predicted
  serialization mechanism, not a wiring bug. Committed deliberately still failing as
  reproducible evidence for the eventual throughput pass (wider `ddram_phy` bursts and/or a
  prefetch-ahead scheduling scheme) — do not loosen this test's checks to force a pass; fix the
  underlying budget instead. What's left before the full raster path is proven: sprite output
  (needs the DDRAM stack wired to `sprite_render_engine`/`sprite_frame_buffer`, which will make
  the throughput picture worse, not better, before it's addressed).

- **All nine `.mra` files reworked to the finalized DDRAM address map.** Every file's ROM
  layout previously used a tightly-packed per-game concatenation (flagged provisional in each
  header since before `docs/phase1_ddram_map.md`'s fixed-region layout existed); now every
  file uses that real, fixed-region map (`maincpu`@`0x000000`/`0x200000`,
  `audiocpu`@`0x200000`/`0x040000`, `sprites`@`0x240000`/`0x800000`,
  `tiles`@`0xA40000`/`0x200000`, `ymsnd:adpcma`@`0xC40000`/`0x100000`,
  `ymsnd:adpcmb`@`0xD40000`/`0x080000`, `spritelut`@`0xDC0000`/`0x040000`), padded with
  `<part repeat="0xNNNN"> FF</part>` filler (matching the precedent in
  rmonic79/Arcade-Raiden_MiSTer's own `.mra` files) wherever a set's actual content is smaller
  than its region's reservation. Every file's total padding cross-checked against hand
  computation before committing. This closes the ROM-layout half of the "not yet consumed by
  any RTL" caveat every file carried — the DIP status-bit-position half is still provisional,
  pending the top-level integration item above.

Every RTL module so far has been verified in ModelSim against an independently-computed
reference (not the RTL's own expressions), exhaustively or near-exhaustively over its realistic
input domain — see individual module headers and commit messages for verification counts and
any bugs (real or false-alarm) found along the way.

## Hardware reality (from the driver, not assumption)

`psikyo.cpp` is **not one uniform board** — even excluding the bootlegs, it's two meaningfully
different sound/protection configurations sharing one video architecture:

| Group | Games | Main CPU | Sound CPU | Sound chip | Protection |
|---|---|---|---|---|---|
| SH201B/KA302C | Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road | 68EC020 @16MHz (32/2 on sngkace) | Z80 @4-8MHz | YM2610 | none |
| SH403/SH404 | Strikers 1945, Tengai | 68EC020 @16MHz | LZ8420M (Z80 core) @8MHz | YMF278B (OPL4) | PIC16C57 @4MHz — **but MAME runs it with `.set_disable()` and fully simulates the protection responses in C++** (`s1945_mcu_*` in psikyo.cpp), it never executes real PIC code |

(Excluded: s1945bl/tengaibl bootlegs — different memory map, OKI M6295 audio instead of YM parts,
no Z80/protection, extra sprite-buffer RAM copy behavior the real boards don't have. Genuinely
different-enough hardware that folding it in would mean maintaining two divergent memory maps and
video-vblank paths for no benefit to genuine-PCB accuracy.)

Video hardware (PS2001B/PS3103/PS3204/PS3305, from `psikyo_v.cpp`) is identical across all of the
above and is entirely custom — this is the real engineering content of the project:

- **2 tilemap layers**, 16×16 tiles, 4 selectable geometries per layer (512×2048 … 4096×256 tiles,
  selected live via a vreg field), per-line *and* per-tile row-scroll, bank-switchable tile source
  (`tilemap_bank` 0-3, +0x2000 tile offset), selectable transparent pen (0 or 15).
- **Zoom sprite engine**: ~0x300 (768) sprite slots in double-buffered spriteram (hardware
  buffers one frame — MAME uses `buffered_spriteram32_device`, copied on vblank rising edge), a
  display list of up to 0x400 indices terminated by `0xFFFF`, each sprite up to 8×8 16×16-pixel
  tiles, per-sprite X/Y zoom (4-bit field, 32=100% down to ~53%), tile code passed through a
  **ROM lookup table** (`spritelut`) before addressing graphics, 2-bit priority vs. the two
  tilemap layers, per-sprite flip.
- **Screen timing**: 320×224, pixel clock `14.31818MHz/2` (7.159MHz), htotal 456, vtotal 262,
  ~59.92Hz, 38 lines vblank — standard MiSTer arcade raw-timing pattern.

## Component reuse map

| Chip | Plan | Source |
|---|---|---|
| 68EC020 | **TG68K.C** (VHDL, only viable open 020 core) | github.com/TobiFlex/TG68K.C — known rough edges in 68EC020 mode; Phase 0 spike required before committing further |
| Z80 (sound CPU) | **T80** (Daniel Wallner core) | embedded directly in dozens of MiSTer-devel arcade cores, e.g. Arcade-TaitoSystemSJ_MiSTer, Arcade-Raiden_MiSTer, Arcade-Galaga_MiSTer — drop-in, low risk |
| YM2610 | **jt10** | github.com/jotego/jtcores (JTFRAME) — pull the module directly rather than adopting full JTFRAME, same way NeoGeo_MiSTer embeds it (Neo Geo's sound board is Z80+YM2610, making that core the best reference for the T80+jt10 wiring pattern) |
| YMF278B (OPL4, Phase 2 only) | **No existing RTL core anywhere.** `ymfm` (github.com/aaronsgiles/ymfm, BSD) is MAME's own C++ model and the best spec/behavior reference, but it's software, not synthesizable. jtopl (jotego) only covers OPL2/3, not OPL4's wavetable+PCM extensions. This will need to be written from scratch against the ymfm reference — budget it as comparable in size to the 68020 CPU risk, not a footnote. | — |
| PIC16C57 | **Not emulated as a CPU.** Reimplement the `s1945_mcu_*` state machine from psikyo.cpp directly as a small RTL FSM — this mirrors what MAME itself does (the PIC is `set_disable()`'d in MAME) | `psikyo.cpp:95-225` |
| LZ8420M | Treat as T80-compatible (it's a Z80 core variant); confirm no divergent behavior is actually exercised before assuming full compatibility | — |
| PS2001B/PS3103/PS3204/PS3305 (tilemap+sprite video) | **Custom RTL, no shortcut.** No FPGA implementation of these exists anywhere (checked). CAVE's zoom-sprite engine (Arcade-Cave_MiSTer) is the closest conceptual analog — 68K-era arcade hardware with double-buffered zoom sprites — but it's Chisel/Scala on a different build pipeline, so it's a *design reference only*, not code to port into a Quartus/Verilog project | `psikyo_v.cpp` (full file read) |
| Top-level framework (HPS, SDRAM ctrl, OSD, raw video timing, MRA/ROM loader glue) | **MiSTer-devel/Template_MiSTer** — the official generic starting point for new cores (per your direction). It's not arcade-specific out of the box, so the arcade-side wiring (MRA-driven ROM loader, per-game DIP/status-bit layout, dual-tilemap+sprite video pipeline shape) should be cross-checked against an existing arcade core built the same way, e.g. rmonic79/Arcade-Raiden_MiSTer or atrac17/Toaplan2 — same era, same "shmup with zoom sprites + banked tile ROMs" shape | github.com/MiSTer-devel/Template_MiSTer (base), github.com/rmonic79/Arcade-Raiden_MiSTer, github.com/atrac17/Toaplan2 (arcade-wiring reference) |
| CRT geometry adjustment | **CRT_Offset module** — standard MiSTer-devel video-timing helper letting users nudge H/V position and porch timing from the OSD, present in most arcade cores of this class | `sys/`-adjacent, wired at the raw video timing generator stage; confirm exact module name/path against a reference core (e.g. Raiden_MiSTer/Toaplan2) when the top-level timing generator is built |
| DIP switches / controls | **Framework-standard status-bit/DIP mapping** — per-game DIP layout comes from each driver's `INPUT_PORTS_START`/DIP tables (already flagged in "Verification strategy" below as needing individual attention per game/region), exposed via the OSD status bits the same way every MiSTer arcade core does; controls mapped through the standard MiSTer input framework (`joystick`/`player_1`/`player_2` conventions), not a custom scheme | `psikyo.cpp` per-game `INPUT_PORTS_START` blocks; `sys/` input framework |
| High score persistence | **hiscore.v** — standard MiSTer-devel high-score save/load module. Needs each game's high-score RAM region/format identified from the driver (or from MAME's own hiscore.dat entries if present for these games) before it can be wired up | github.com/MiSTer-devel (hiscore.v is a common, mostly-generic module across many arcade cores) — Phase 2/polish-stage item, not needed for initial bring-up |

## Phased roadmap

**Phase 0 — CPU spike (de-risk before committing to the full plan)**
Stand up TG68K.C alone in a minimal Quartus 17.x project on the DE10-nano, boot it against a
Psikyo ROM's POST/reset code, and confirm 68EC020-mode instruction coverage is sufficient. This
is the one component with no fallback if it's broken — resolve first.

**Phase 1 — SH201B/KA302C hardware (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road)**
Simplest sound/protection config (Z80+YM2610, no MCU, no YMF278B) — proves out the full pipeline:
TG68K.C integration, T80+jt10 sound subsystem, SDRAM tile/sprite ROM banking, and the from-scratch
tilemap + zoom-sprite video engine (the hard part, and shared unchanged by every later phase).
Exit criteria: all three games booting, correct sprite zoom/priority, correct tilemap
size-switching and row-scroll, working `.mra` files for each region variant in the driver's
input-port tables.

**Phase 2 — SH403/SH404 hardware (Strikers 1945, Tengai)**
Adds the simulated-PIC protection FSM and, the larger item, the from-scratch YMF278B core. Given
the YMF278B has no existing implementation, treat "get real YMF278B audio correct" as its own
sub-milestone with its own de-risking spike (start from `ymfm`'s C++ behavior as the golden
reference), gated separately from the rest of Phase 2's bring-up. This is also the final phase —
with bootlegs out of scope, Phase 2 closing out (region/DIP sweep, remaining `.mra` variants, save
states if desired, final timing/accuracy passes) completes the project.

## Verification strategy

- **Simulation-first for the video engine**: the tilemap/sprite logic is complex enough (4 dynamic
  tilemap geometries, per-line/per-tile rowscroll, LUT-indirected zoom sprites) that it should be
  testbenched against known-good frame data pulled from MAME (`-debug`/frame dump or a custom MAME
  trace) before ever touching hardware — this is standard practice for the CAVE/Toaplan2-class
  cores this project is modeled on.
- **Per-game `.mra` correctness**: build MRAs directly from each driver's `ROM_START` block and
  `INPUT_PORTS_START`/DIP tables (region CONFNAME blocks differ per game — samuraia/sngkace/
  gunbird/btlkroad/s1945 each have their own region-bit encoding, don't assume they match).
- **Hardware bring-up**: DE10-nano + Quartus 17.x build per phase exit criteria above; A/B against
  MAME frame-by-frame for sprite zoom curve accuracy and tilemap size-switch glitches (both
  flagged as "not quite right" in the driver's own comments). With no PCB available, MAME is the
  only ground truth this project has — treat matching it as the correctness bar, not real silicon.

## Repository setup

Dev repo lives at **`D:\Mister-Psikyo`**, a new local git repository (`git init`, no remote
required) seeded from **MiSTer-devel/Template_MiSTer**. This is separate from the current working
directory (`_Arcade` inside `meatcores-main`), which is your personal MiSTer *distribution* folder
for prebuilt `.rbf`/`.mra` deployment, not a source tree — only the finished `.rbf`/`.mra` outputs
get copied over to `_Arcade/cores` once builds are ready, the way your other cores already are.

**Release artifacts** (once builds exist — not yet, still deep in RTL): the generated per-game
`.mra` files plus the compiled `.rbf`, named `Arcade-Psikyo_{date}.rbf`, get committed into a
`releases/` folder in this repo.

## Open items / assumptions to revisit

- **No original Psikyo PCB** (confirmed) — this project is built purely from MAME source +
  datasheets/chip documentation, with no genuine-hardware bus/video signals to capture as ground
  truth. That makes **MAME's own emulated output the de facto accuracy target**, including its
  acknowledged uncertainties: the driver's own comments flag the layer-enable bits, sprite zoom
  curve, and tilemap size-switch behavior as "not quite right" / unverified, and there's no board
  to resolve those beyond matching MAME's behavior as closely as possible.
  Separately: **DE10-nano hardware bring-up is available** — copy `.rbf`/`.mra` over and launch
  manually, and (as of 2026-08-21) a MiSTer is set up with a USB Blaster II-style cable to the
  DE10-nano's JTAG port, meaning direct Quartus programming/debug should become possible in
  addition to the copy-and-launch black-box flow. **Not yet reachable from this dev
  environment**: `jtagconfig` reports "No JTAG hardware available" and no Blaster/FTDI device
  shows up in Windows' device list on this machine — the cable may be connected to a different
  machine than this session runs on, or not yet fully connected/drivers not installed. Revisit
  (recheck `jtagconfig`) before assuming JTAG programming is actually usable from here.

  **Reference for when JTAG bring-up actually starts**: danifunker/lbmactwo_MiSTer's
  `docs/MISTER_HARDWARE_DEBUGGING.md` (github.com/danifunker/lbmactwo_MiSTer, a real DE10-nano
  Cyclone V core) documents the practical workflow in useful detail — worth reading in full at
  that point, not just this summary:
  - **Programming**: JTAG chain has 2 devices (HPS at position 1, FPGA at position 2) — program
    with `quartus_pgm -c 1 -m jtag -o "p;output_files/<name>.sof@2"` (the `@2` matters; wrong
    device targets the HPS instead of the FPGA). `quartus_pgm --list`/`-a` to check detection.
  - **In-system probing without rebuilding**: prefers Altera `altsource_probe` (ISSP) megafunction
    instances over SignalTap for a design near its ALM budget — SignalTap costs block RAM/fit
    margin, ISSP costs less and is read via a Tcl script (`quartus_stp_tcl -t script.tcl`) against
    a running bitstream. Their design (~80% ALM with a lite 68881 FPU) caps out around 19 probes
    before fit failures; each probe is deliberately kept read-only and 4-char-tagged.
  - **Debugging patterns**: a free-running counter tied to a bus-cycle strobe (e.g. `_cpuAS`) that
    stops advancing is how they detect a hung CPU; *shifting* (not constant) video noise between
    screenshots indicates VRAM scanout reading stale data under SDRAM arbiter starvation, not a
    fixed addressing bug — directly the same failure family as this project's own SDRAM
    contention work (`docs/phase1_sdram_map.md`'s residual-throughput findings, and the real
    byte-order bug `rtl/memory/gfxrom_byte_reorder.sv` fixed) — worth specifically checking for
    both patterns (byte-order and arbiter starvation) once this project reaches real hardware,
    since sim can't surface either on its own (their doc's own "sim vs. hardware" list names both
    as things Verilator-only testing missed for them too).
  - **MiSTer only auto-loads ROM index 0** — a second ROM region (their case: a declaration ROM)
    needs baking into the bitstream via `$readmemh` if used, not relying on HPS download. Worth
    checking against this project's own `.mra` region layout once top-level integration wires up
    `ioctl_download` for real.
  - Screenshot capture via the MiSTer Remote web API: `curl -s -X POST
    http://<mister-ip>:8182/api/screenshots`.
- **YMF278B de-risking spike** should probably happen early (maybe alongside Phase 0) rather than
  right before Phase 2, given it's the other component with no existing shortcut — worth deciding
  scheduling once Phase 1 is underway and its actual cost is clearer.
- **Sprite frame-renderer throughput is still unbudgeted at the whole-frame/whole-game level,
  though one real single-sprite data point now exists.** `sim/port2_sdram_tb/tb_port2_sdram.sv`
  measured one real 16×16 (1 sub-tile) sprite against the actual SDRAM transport (not the ~4-cycle
  synthetic ROM latency the rough math below assumed): 514 cycles alone, 736 under sustained
  maincpu+audiocpu contention. Extrapolating that single-sub-tile cost across a worst-case
  display list is still the open question — 1023 entries × up to 64 sub-tiles/entry (8×8-tile
  sprites) would be far beyond one frame period at any realistic clock, but real games are
  extremely unlikely to hit that theoretical worst case, and this hasn't been checked against
  actual per-game sprite/sub-tile counts (no MAME frame trace pulled yet). Revisit once real
  per-game numbers are known — may need a per-sub-tile cycle budget/drop-excess bound, a faster
  render clock, or reduced ROM latency (e.g. wider on-chip gfx ROM bursts).
- **samuraia/sngkace ADPCM-A sample ROM needs a bit 6/7 swap not yet implemented anywhere.**
  MAME's `init_sngkace()` (psikyo.cpp) applies `out[7]=in[6], out[6]=in[7]` to the entire
  `ymsnd:adpcma` region for samuraia/samuraiak/sngkace/sngkacea ONLY — confirmed directly from the
  driver's `GAME()` table, not gunbird/btlkroad despite identical sound hardware, and not either
  Phase 2 game. This is a real ROM-mastering artifact (Samurai Aces/Sengoku Ace's audio will
  decode as garbage without it), can't be expressed in `.mra` (byte-level format only, no
  intra-byte bit permutation), and needs a per-game select signal to gate it correctly since it
  must not apply to Gun Bird/Battle K-Road sharing the same core. Full writeup and RTL options in
  `docs/phase1_memory_map.md`'s new "samuraia/sngkace ADPCM-A sample ROM: bit 6/7 swap" section —
  belongs in the sound subsystem work below, most naturally as a download-time fixup alongside
  `sdram_download.sv`.

## Next steps

See "Progress" above for current status. Immediate next items, in order:

1. Top-level integration against Template_MiSTer: wiring the video/sound engines + TG68K.C into
   `emu.sv`, the CRT_Offset module, DIP/status-bit + control mapping, and (later-stage/polish, not
   needed for initial bring-up) hiscore.v — see "Component reuse map" above. Gfx/CPU ROM streaming
   goes through the SDRAM stack (`sdram_phy`/`sdram`/`sdram_arbiter*`/`sdram_narrow_bridge`, see
   `docs/phase1_sdram_map.md`) now, not DDRAM — the DDRAM stack (`ddram_phy`/`ddram_arbiter`/
   `ddram_download`) is built and still available but is no longer Phase 1's critical path (see
   `docs/phase1_ddram_map.md`'s header note). Every gfx-ROM-row consumer (tilemap ×2, sprite)
   MUST route through `rtl/memory/gfxrom_byte_reorder.sv` between the SDRAM controller and its
   `gfxrom_data` port — easy to forget since it compiles and even *runs* fine without it, just
   produces byte-order-scrambled tile/sprite graphics (see "Progress" above for the real bug this
   caught). `sdram_narrow_bridge.sv` consumers (spritelut, `maincpu`, `audiocpu`) must NOT use it.
   This is also where the `.mra` files' DIP status-bit
   positions (see "Progress" above) get checked against real RTL for the first time and corrected
   if needed. Sound CPU wrappers (`sound_cpu_sngkace`/`gunbird`) now have req/valid ROM ports
   (see "Progress" above) and are ready to connect to a real arbiter/`sdram_narrow_bridge`
   (`WORD_BYTES=1`, matching the Z80's 8-bit fetch) for this pass — not wired yet, but no longer
   blocked.
2. Sound subsystem: a real jt10 verification pass (audio-domain, not just compile-clean — see
   `rtl/sound/jt10/PROVENANCE.md`) before actually wiring it into either sound CPU wrapper's YM
   I/O chip-select bus; ADPCM-A/B ROM banking once jt10 itself is trusted; and applying the
   samuraia/sngkace ADPCM-A bit 6/7 swap (see the open item above) during ROM download.
3. DE10-nano black-box bring-up once a build exists.
