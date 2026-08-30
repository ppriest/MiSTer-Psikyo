# Psikyo (PS1/PS2) MiSTer Core — Roadmap

## Context

Goal: a DE10-nano MiSTer core for the original Psikyo shooter hardware emulated by MAME's
`psikyo.cpp` / `psikyo_v.cpp` (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road, Strikers 1945,
Tengai — the genuine PCB sets; bootleg boards are explicitly out of scope, see below) — a Quartus
17.x Verilog/SystemVerilog project producing one `.rbf` and a `.mra` per supported game, reusing
proven open MiSTer components where they exist and building custom RTL for the two Psikyo-specific
video ASICs (tilemap + zoom-sprite engine) that have no existing FPGA implementation anywhere.

Decisions: narrow game scope first, bootleg boards dropped entirely (variant hardware, no real
coverage benefit), TG68K.C for the CPU, simulated PIC protection (matching MAME) with a real
YMF278B core for Phase 2.

For detailed, cross-cutting technical findings (Quartus-vs-ModelSim divergences, SDRAM/DDRAM
gotchas, testbench pitfalls, real-hardware bring-up technique) see
**[`docs/LESSONS_LEARNED.md`](LESSONS_LEARNED.md)** — that doc is where debugging war stories and
"how we found bug X" narratives live now; this file stays focused on current status and what's
next. Per-component vendoring/provenance detail lives in each module's own `PROVENANCE.md`
(`rtl/cpu/tg68k/`, `rtl/memory/sdram/`, `rtl/sound/jt10/`, `rtl/sound/jt49/`).

## Progress (kept current — last updated 2026-08-29)

**Phase 0 — CPU spike: complete.** TG68K.C vendored, boots and executes 68020-mode code correctly
in ModelSim, synthesizes/fits cleanly on real Cyclone V (2,788/41,910 ALMs).

**Phase 1 — SH201B/KA302C hardware (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road):
all three games boot and run on real hardware.** The board variant is selected at
runtime from the `.mra` mod byte, so one `.rbf` serves all three.

Remaining Phase 1 work (see "Next steps" below for detail on each): audio has residual
distortion/crackle (samuraia/sngkace's ADPCM-A bit-swap and the samuraia no-music defect are
fixed and verified; a listening test on a fully-constrained build confirms the residue is NOT
a timing artifact — the identified cause was the ADPCM-B data input tied to zero, fix
implemented `fedadcf`, listening verification pending — see "Fix sound"), and the sprite
render slowdown under load is unresolved (a first fix attempt measured worse, not better).
`clk_sys` timing is close to closed: the audited multicycle constraints (T80, pixel→palette,
jt12 families, 2026-08-29) eliminated their violation families; the render engine's
per-column path remains the one known violation family, by choice (a pipelining attempt
closed it fully but regressed scene transitions on hardware and was reverted — see "Timing
closure" in Open items). Sound is otherwise wired and producing output (was previously not
wired in at all), and the earlier tinted-colours defect on Gun Bird/Battle K-Road is gone.

Built and verified (ModelSim + real Quartus synthesis, each with its own testbench — see git
history for individual commits):

- Memory map (`docs/phase1_memory_map.md`), video engine design (`docs/phase1_video_engine.md`).
- Tilemap engine (`tilemap_line_engine.sv` + combinational stages) and zoom sprite engine
  (`sprite_render_engine.sv`, `sprite_frame_buffer.sv`, `sprite_display_list_walker.sv`, etc.) —
  full display-list walk → attribute fetch → zoom/position → spritelut → gfx fetch → pixel write
  pipeline, double-buffered.
- Compositor (`compositor.sv`) — a pure combinational priority resolver: both tilemap layers +
  the sprite frame buffer resolve, per MAME's priority/transparent-pen rules (`primask`
  bit-indexed by the destination priority value, pdrawgfx convention), into TWO parallel
  palette lookups — the live palette for tilemap/backdrop (`pal_addr`) and the sprite-palette
  snapshot (`pal_s_addr`) — plus a `sprite_sel`; the final registered RGB mux lives in
  `rtl/psikyo_core.sv`.
- Sound subsystem: T80 (Z80) + jt10 (YM2610) vendored and wired into the sound CPU's YM I/O bus
  (`rtl/psikyo_top.sv`'s `ym_din`/`ym_dout`, `u_ym2610`); `rtl/sound/sound_cpu.sv` (one module,
  runtime `board_gunbird` select — it replaced the compile-time sngkace/gunbird pair) wraps T80
  against each board's real memory/IO map with verified req/valid
  ROM timing (see LESSONS_LEARNED.md's T80 section). jt10's SSG (jt49) channel verified as a real
  audio-domain functional test, and hardware now produces music and effects — see "Next
  steps" item 4 for what's still open (residual distortion/crackle; ADPCM-B fix implemented,
  listening verification pending).
- `.mra` files done for all 4 Phase 1 parent games + every MAME clone set (`releases/`,
  `releases/_alternatives/`), built directly from each game's `ROM_START`/`INPUT_PORTS_START`
  blocks, using the finalized SDRAM address map. DIPs arrive as a separate ioctl download
  (index 254, 8 bytes), not through the status word — see `docs/mister_framework_notes.md`.
- SDRAM backend (`rtl/memory/psikyo_sdram_top.sv`): burst-4 `sdram.sv` (Sorgelig reference,
  extended — see `rtl/memory/sdram/PROVENANCE.md`), 3 dedicated ports (tilemap layer 0/1) +
  5-way arbitrated port (sprite gfxrom/spritelut/maincpu/audiocpu/HPS download). Verified via a
  real HPS-download-then-read round trip through all 6 client ports, and under sustained
  maincpu+audiocpu contention (0 pixel mismatches). DDRAM stack (`ddram_phy`/`ddram_arbiter`/
  `ddram_download`) was tried first, found unsuitable for this traffic's latency budget, and is
  no longer Phase 1's critical path — kept, not deleted, since its arbiter design was reused
  directly for the SDRAM arbiters (see `docs/phase1_ddram_map.md`'s header note).
- `rtl/cpu/maincpu.sv`: 68EC020 wrapper — address decode + DTACK for the full `psikyo_map`
  (ROM via req/valid, all 6 BRAM regions, input ports, sound latch, held-autovectored vblank IRQ).
  Verified: ROM fetch, all BRAM regions, input-port read, sound-latch write **and the held
  level-4 autovectored vblank IRQ** all PASS (`sim/maincpu_tb/tb_maincpu.sv`, Cases 1 and 2).
  The vblank IRQ was recorded here for a long time as a known open CPU bug ("vector-table fetch
  address comes out wrong"); that was a misreading of a bus trace. **Resolved 2026-08-23: the
  fetch address was always correct (`0x70`) — the testbench's own `$readmemh` was overwriting the
  vector table after it had been installed.** See `rtl/cpu/tg68k/PROVENANCE.md`. No RTL change was
  needed. Interrupt-driven integration is cleared for use.
- `rtl/psikyo_core.sv` (video+CPU) and `rtl/psikyo_top.sv` (+ SDRAM backend + sound CPU) —
  full board assembly, verified end-to-end: a real CPU program downloaded through the actual HPS
  path lands the expected pixel in the compositor's `rgb` output
  (`sim/psikyo_top_tb/tb_psikyo_top.sv`, full regression PASSES).
- `Psikyo.sv` top-level: instantiates the full chain against `hps_io`, a real PLL
  (`clk_sys` = 85.909091MHz, 12:1 `ce_pix` divider), real video output. **Synthesizes cleanly
  under real Quartus 17.0**: 0 errors, 22382 logic cells, 1349 RAM segments, 3 PLLs, 39 DSP
  elements. First full place-and-route (`.sof`/`.rbf`) also complete. **Timing closure was NOT
  achieved for a long time and this was not noticed** — see the 2026-08-23 root-cause note below;
  always read `output_files/<rev>.sta.summary`, never trust "Fitter was successful". (Timing has
  since been brought to near-closure with one accepted violation family, 2026-08-29 — see
  "Timing closure" in Open items.) The board variant is selected at runtime from the `.mra` mod byte, so one `.rbf` serves all three games.

**Hardware bring-up history has moved to `LESSONS_LEARNED.md`.** It was a long chronological
narrative of failures and fixes, which belongs there rather than in a design document. The bugs
it covered, in case you are looking for one: the RESET/HALT tri-state synthesis bug in
TG68K.vhd; the design not closing timing while every log line said "successful"; the ROM download
never reaching SDRAM because MiSTer holds core reset for its duration; the maincpu `.mra`
interleave delivering byte-swapped words; the tilemap layer-enable polarity; and the tilemap
display side consuming at `clk` instead of `ce_pix`.


## Hardware reality (from the driver, not assumption)

`psikyo.cpp` is **not one uniform board** — even excluding the bootlegs, it's two meaningfully
different sound/protection configurations sharing one video architecture:

| Group | Games | Main CPU | Sound CPU | Sound chip | Protection |
|---|---|---|---|---|---|
| SH201B/KA302C | Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road | 68EC020 @16MHz (32/2 on sngkace) | Z80 @4-8MHz | YM2610 | none |
| SH403/SH404 | Strikers 1945, Tengai | 68EC020 @16MHz | LZ8420M (Z80 core) @8MHz | YMF278B (OPL4) | PIC16C57 @4MHz — **but MAME runs it with `.set_disable()` and fully simulates the protection responses in C++** (`s1945_mcu_*` in psikyo.cpp), it never executes real PIC code |

(Excluded: s1945bl/tengaibl bootlegs — different memory map, OKI M6295 audio instead of YM parts,
no Z80/protection, extra sprite-buffer RAM copy behavior the real boards don't have.)

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
| 68EC020 | **TG68K.C** (VHDL, only viable open 020 core) | github.com/TobiFlex/TG68K.C |
| Z80 (sound CPU) | **T80** (Daniel Wallner core) | embedded in dozens of MiSTer-devel arcade cores (Arcade-TaitoSystemSJ_MiSTer, Arcade-Raiden_MiSTer, Arcade-Galaga_MiSTer) |
| YM2610 | **jt10** | github.com/jotego/jtcores (JTFRAME) — pulled directly, same pattern as NeoGeo_MiSTer |
| YMF278B (OPL4, Phase 2 only) | **No existing RTL core anywhere.** `ymfm` (github.com/aaronsgiles/ymfm, BSD) is MAME's own C++ model, best spec/behavior reference but not synthesizable. jtopl only covers OPL2/3. Written from scratch against `ymfm` — comparable risk/size to the 68020 CPU. | — |
| PIC16C57 | **Not emulated as a CPU.** Reimplement `s1945_mcu_*` from psikyo.cpp as a small RTL FSM (mirrors MAME's own `set_disable()` approach) | `psikyo.cpp:95-225` |
| LZ8420M | Treat as T80-compatible; confirm no divergent behavior is actually exercised | — |
| PS2001B/PS3103/PS3204/PS3305 (tilemap+sprite video) | **Custom RTL, no shortcut.** CAVE's zoom-sprite engine (Arcade-Cave_MiSTer) is a design reference only (Chisel/Scala, different pipeline), not portable code. | `psikyo_v.cpp` |
| Top-level framework | **MiSTer-devel/Template_MiSTer**, cross-checked against rmonic79/Arcade-Raiden_MiSTer / atrac17/Toaplan2 for arcade-specific wiring | github.com/MiSTer-devel/Template_MiSTer |
| CRT geometry adjustment | **CRT_Offset module** — standard MiSTer-devel helper, not yet wired in | confirm exact path against Raiden_MiSTer/Toaplan2 when built |
| DIP switches / controls | Framework-standard status-bit/DIP mapping, per-game layout from `INPUT_PORTS_START` | `psikyo.cpp`, `sys/` |
| High score persistence | **hiscore.v** — standard module, Phase 2/polish item | github.com/MiSTer-devel |

## Phased roadmap

**Phase 0 — CPU spike: complete** (see Progress above).

**Phase 1 — SH201B/KA302C hardware (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road): all
three games boot and run; residual audio distortion/crackle (cause identified, fix
implemented, listening verification pending) and the render-time slowdown remain open (see
"Next steps").** Exit criteria: all
three games booting, correct
sprite zoom/priority, correct tilemap size-switching and row-scroll, working `.mra` files for
each region variant.

**Phase 2 — SH403/SH404 hardware (Strikers 1945, Tengai): not started.** Adds the simulated-PIC
protection FSM and the from-scratch YMF278B core (its own de-risking spike, gated separately from
the rest of Phase 2). Final phase — closing it out (region/DIP sweep, remaining `.mra` variants,
save states if desired, final timing/accuracy passes) completes the project.

## Verification strategy

- **Simulation-first for the video engine**: testbenched against known-good/independently-derived
  reference data before touching hardware, standard practice for CAVE/Toaplan2-class cores.
- **Per-game `.mra` correctness**: built directly from each driver's `ROM_START`/
  `INPUT_PORTS_START`/DIP tables — region encodings differ per game, never assumed to match.
- **Hardware bring-up**: DE10-nano + Quartus 17.x build per phase exit criteria; A/B against MAME
  frame-by-frame for sprite zoom curve accuracy and tilemap size-switch glitches (both flagged as
  "not quite right" in the driver's own comments — with no PCB, MAME's own output is the accuracy
  target, not real silicon behavior beyond what MAME itself gets right).

## Repository setup

Dev repo: **`D:\Mister-Psikyo`**, local git repo (`origin` → github.com/ppriest/MiSTer-Psikyo.git),
seeded from **MiSTer-devel/Template_MiSTer**. Separate from `_Arcade` (personal MiSTer
distribution folder — only finished `.rbf`/`.mra` outputs get copied there, not a source tree).
Convention: `develop` is the working branch, `master` only gets merges when explicitly asked.

**Builds are staged, not run in-tree**: `scripts/build_staged.py` snapshots HEAD into a git
worktree at `build/` (gitignored) and runs the full Quartus flow there, so the main tree stays
editable during the ~14-minute compile; the log (`q_staged.log`), `output_files/` (the `.rbf`
and `.sta.summary`) and a `BUILT_COMMIT` stamp all land under `build/`. A dirty tree is refused
by default — the build is exactly HEAD. Default revision is the instrumented `Psikyo_stp`
(fitter SEED pinned at 7 in `Psikyo_stp.qsf` — the default-seed fit did not boot); pass
`--rev Psikyo` for a release build.

**Release artifacts**: generated per-game `.mra` files plus the compiled `.rbf`, named
`Arcade-Psikyo_{date}.rbf`, committed into `releases/`.

## Open items / assumptions to revisit

- ~~**Pause function, mapped to a controller button**~~ **DONE.** Implemented (commit `66d5115`)
  and moved onto the dedicated Pause button, joystick bit 12 (commit `b9d3d80`) — see `Psikyo.sv`.
  Listed in README's "Working, confirmed on hardware".
- **No original Psikyo PCB** (confirmed) — MAME's own emulated output is the accuracy target,
  including its acknowledged uncertainties (layer-enable bits, sprite zoom curve, tilemap
  size-switch behavior all flagged "not quite right" in the driver itself).
  DE10-nano hardware bring-up IS available and underway (see Progress above) — a MiSTer is set
  up with SSH access and a USB Blaster II-style JTAG cable. JTAG/ISSP is now fully reachable and
  in active use (commit `078738a` onward): a tilemap VRAM write probe (`"W"`), a spriteram read
  probe (`"S"`), an L1 fetch-pipeline probe (`"V"`), a frame-count auto-pause (`"F"`) and
  sound-chain debug counters (`"A"`) are all live over JTAG today (see README's "Debugging on
  hardware" and `docs/TILEMAP_BUG.md`'s "Live-hardware evidence" section for real captures taken
  this way). See LESSONS_LEARNED.md's "Real hardware bring-up" section for the working
  SSH/SCP/Remote-API deploy flow, and danifunker/lbmactwo_MiSTer's
  `docs/MISTER_HARDWARE_DEBUGGING.md` for further JTAG-specific technique (ISSP probing, JTAG
  chain addressing) if a deeper dive is needed.
- **YMF278B de-risking spike** should probably happen early (maybe alongside/soon after Phase 1
  wraps) rather than right before Phase 2 — worth deciding scheduling once Phase 1 hardware
  bring-up is further along.
- **CRT offset** — standard MiSTer per-core screen positioning (H/V offset status bits, matches
  the framework's usual `CRT_OFFSET` convention) not yet wired up. Added to the list 2026-08-29,
  not yet scoped.
- **hiscore.v** — MiSTer's standard high-score-save framework (EEPROM/RAM-backed, save/restore
  via the OSD) not yet integrated. Needs the per-game hiscore.dat memory maps (same shape as any
  other MiSTer-devel arcade core's hiscore support) — not yet scoped. Added 2026-08-29.
- **Fast ROM loading via DDR3** — the HPS `ioctl_download` path currently streams straight into
  the onboard SDR SDRAM chip a byte at a time (`sdram_download.sv`); loading through the HPS-side
  DDR3 instead (much higher bandwidth) would speed up the download phase. Related to, but
  distinct from, the dormant `ddram_arbiter`/`ddram_phy` DDR3 path being stood up for sprite gfxrom
  (see "Fix the slowdown" above) — worth doing together if that work goes ahead, since both need
  the same DDR3 plumbing live. Added 2026-08-29, not yet scoped.
- ~~**Game-driven sprites-disable freezes, not blanks, the sprite display bank.**~~ FIXED
  2026-08-29: per the MAME renderer's author the enable is deliberately LIVE —
  `spriteram_dbuf.sv` now exports the last CPU-written `ctrl_shadow[0]` and it gates the
  compositor's `sp_present` directly, so sprites blank the moment the game writes the bit.
  See `docs/sprite_buffering.md` defect 5.
- **Sprite frame-renderer throughput is unbudgeted at the whole-frame/whole-game level.** One real
  single-sprite data point exists (`sim/port2_sdram_tb/`: 514 cycles alone, 736 under sustained
  contention) but extrapolating across a worst-case display list (1023 entries × up to 64
  sub-tiles/entry) hasn't been checked against real per-game sprite/sub-tile counts. Revisit once
  real per-game numbers are known.
- ~~**samuraia/sngkace ADPCM-A sample ROM needs a bit 6/7 swap.**~~ **DONE 2026-08-29**
  (commit `9bbd8dd`): implemented as a download-time fixup in
  `rtl/memory/psikyo_sdram_top.sv` (`needs_adpcma_swap`, gated by `mod_board[1]` from the
  `.mra`'s mod byte). Fixes samuraia/sngkace's ADPCM-A sample decode specifically; the
  remaining audio defect's cause (Gun Bird needs no swap per MAME) has since been identified
  as the un-wired ADPCM-B channel — see "Next steps" item 4's evening update. Full writeup in
  `docs/phase1_memory_map.md`. Note the swap only took effect once the `.mra` mod byte was
  moved BEFORE the ROM it gates (commit `eafa783`).
- **Timing closure — nearly closed 2026-08-29; one known violation family remains, by
  choice.** Four audited multicycle constraint families — TG68K kernel (pre-existing), T80
  sound CPU (`21be3ff`), video pixel-path → palette lookups (`f7a502d`), and jt12 slot-scan →
  phase generator (`0bfda29`), later extended to the audited lfo/detune/sh_rst sibling
  families (`018f70a`) — each recorded WITH its audit reasoning in `Psikyo.sdc` itself (the
  constraint methodology and its lesson references live there; keep them), eliminated their
  whole violation families: `clk_sys` TNS fell from ≈ −300 at the start of the day through
  −63 → −11.7 → −11.1 → −7.2. A pipeline stage in the sprite render engine's per-column pixel
  path (`61e08a8`) then reached full closure (worst slack −0.031 ns, TNS −0.123, build of
  `018f70a`) — but it visibly REGRESSED scene transitions on real hardware and was REVERTED
  (`6325b02`): correct rendering wins over the last picoseconds. The render engine's
  full-rate per-column path therefore returns as the design's one KNOWN `clk_sys` violation
  family (approximately −1.2 ns worst, as before the attempt — silicon-tolerated for months
  of working builds); a future re-attempt must first understand why the extra pipeline
  latency interacted with scene transitions. The other residue is milli-ns fit noise in the
  vendored `sys/` scandoubler (unconstrained by the framework's own `sys_top.sdc`, and
  inactive on this project's HDMI-framebuffer output path) and trivial `jt12_mmr`
  stragglers. History, for anyone re-reading old reports: the dominant offender was once
  `sprite_record_fetch.word_y -> sprite_render_engine.fb_pixel` at −1.889 ns (TNS −156),
  addressed by the (still in place) stage-A/B pipelining pass; a later measurement blamed a
  DSP-multiply path in `sprite_line_engine` (−2.463 ns / TNS −226.5), a module since DELETED
  along with the line-buffer sprite renderer, so that path no longer exists.

## Next steps

(Resolved from the previous list: sprites are fixed; no unexpected tint remains; HDMI
rotation confirmed good on a display. Sound is now hooked up and producing real output
during play, not just at boot — still not fully correct, see item 4.)

1. ~~**Fix the tilemap bug**~~ — **DONE 2026-08-29**: `docs/TILEMAP_BUG.md`. A gfxrom
   req/valid handshake protocol bug (stale request re-sampled by `sdram_phy`, every
   response consumed one request behind) — fixed in `tilemap_line_engine.sv`
   (commit `f54e69b`), confirmed on hardware.
2. ~~**Fix tilemap↔sprite priority**~~ — **DONE 2026-08-29, verified on hardware.**
   Two stacked defects: the `primask` table needed entry 2 corrected from MAME's
   published `0xFF` to `0xFE` (direct from the author of MAME's Psikyo renderer,
   commit `0c63a5b`), and — the actual root cause — the mask was applied as a
   value-AND instead of BIT-INDEXED by the destination priority value (MAME's
   pdrawgfx convention), which let priority-1 sprites beat tilemap 1 unconditionally
   (commit `284cad6`). Root-caused by dumping the live paused cloud scene through the
   JTAG spriteram probe (instance `"S"`, `scripts/read_spriteram.tcl dump`, decoded
   with `scripts/decode_spriteram.py`): all six cloud sprites carried priority 1,
   which must lose to layer 1.
3. ~~**Investigate sprites briefly showing wrong colours between scenes**~~ —
   **DONE 2026-08-29** (commit `b7b5d8e`): sprites read a 512-entry snapshot of their
   palette half, copied at `frame_start`, so sprite pixels and colors change scene
   together; tilemaps render live and keep the live palette. Confirmed on hardware:
   both transition symptoms are gone — the miscolour flash AND the briefly-visible
   stale sprites (the latter first looked like a separate swap/clear sequencing
   defect, but disappeared with the palette snapshot: stale pixels recolored by the
   new scene's palette had read as wrongly-present sprites — see
   `docs/sprite_buffering.md` defect 4).
4. **Fix sound** — IN PROGRESS; music and effects play, the ADPCM-A defects are verified
   fixed, and the residual distortion/crackle has an identified cause with the fix
   implemented, listening verification pending (see the evening update at the end of this
   item). Four root causes found and fixed —
   the 68020's sound-latch
   writes never decoded unless byte-addressed exactly (word/long writes missed; measured
   as latch-writes=0 through real gameplay); the Z80 ran at 21× real speed (CLKEN=1 —
   the garbled jingle); a spurious ROM re-request poisoned the handshake under the
   CLKEN-stretched T-states; and sdram_arbiter6's round-robin picker had a 3-bit
   overflow that never scanned the audiocpu client from rr_ptr==4 (solo-requester
   deadlock). All reproduced+verified against the real transport in sim
   (sim/sound_irq_tb/tb_sound_irq_sdram.sv, real 3.u71 ROM). On hardware
   (Arcade-Psikyo_20260866): audio output nonzero for the first time, latch commands
   streaming during demo play on both boards, no freezes. Open at the time, all since
   resolved (see the evening update below): ADPCM-A fetched only ~4 bytes; sound
   quality/tempo needed a human listen; and snd_irq_en (status[51]) had to be ON — its
   default has since been flipped.
   Older root-cause notes: (superseded) — sound work so
   far is recorded in `docs/LESSONS_LEARNED.md` (Z80 alive, latch decode correct, 46 YM
   writes at boot then nothing; enabling the timer IRQ locks the Z80 solid — do not
   re-enable blind).

   **Update 2026-08-29 (later same session):** the samuraia/sngkace ADPCM-A bit 6/7
   sample-ROM swap (see "Open items" below) is now implemented (`needs_adpcma_swap`,
   `rtl/memory/psikyo_sdram_top.sv`, gated by `mod_board[1]` from the `.mra` mod byte —
   commit `9bbd8dd`) and verified in sim. It does not explain the whole picture: ADPCM-A
   playback is garbled on Gun Bird too, and Gun Bird needs no swap per MAME, so a second,
   unidentified cause of ADPCM-A corruption remains open. Checked and ruled out as
   causes: YM2610 clock frequency (verified exact 8 MHz) and the SDRAM granule-cache
   handshake protocol (`sdram_narrow_bridge.sv`). *(The remaining audio defect now has an
   identified cause — see the evening update below.)*

   **Update 2026-08-29 (evening):** the ADPCM-A swap is now verified by ear on hardware —
   the missing piece was `.mra` ordering: the mod byte gating `needs_adpcma_swap` must be
   sent BEFORE the ROM it gates (commit `eafa783`, all nine `.mra`s reordered — see
   LESSONS_LEARNED's "The mod byte must precede the ROM it gates"). samuraia's missing
   music is fixed: the YM2610 timer IRQ must reach the Z80, and Sound IRQ now defaults ON
   (`status[51]` inverted so a fresh/all-zero `.CFG` gets music; OSD order "On,Off" —
   commit `8dbcb51`; the old "enabling it locks the Z80 solid" behaviour is gone with the
   four transport fixes above, and `scripts/write_cfg.py` seeds it ON in fresh CFGs). A
   listening test on a fully-constrained build (20260876) confirms residual
   distortion/crackle persists and is NOT a timing artifact. Root cause identified: jt10's
   ADPCM-B (delta-T) data input was hardwired to zero (`.adpcmb_data(8'd0)`,
   `rtl/psikyo_top.sv`), so any track using the delta-T channel decoded constant zeros and
   mixed garbage into the output — on these boards ADPCM-B shares the ADPCM-A sample
   region (MAME's YM2610 default when no separate delta-T ROM exists). Fix implemented
   (commit `fedadcf`: the channel reads that SDRAM region through arbiter client c0, freed
   by the sprite-gfxrom repartition; testbench regression passing) — NOT yet verified by
   ear on hardware.
5. **Fix the slowdown** — IN PROGRESS, first re-partition attempt measured WORSE, not
   better (2026-08-29). Step 1 (granule cache in `sdram_narrow_bridge.sv`, commit
   `153f772`) removed most CPU/lut Port 2 traffic — not independently re-measured but
   plausible on its own. Step 2 (commit `430c1ed`): gave sprite gfxrom a dedicated
   Port 1 (was sharing the 5-way Port 2 with the CPUs) by merging both tilemap layers
   onto a shared Port 0 (was two dedicated ports, `sdram_arbiter2.sv`). Pre-repartition
   hardware baseline: `sp_render_max` = 610,255 clk (7.1 ms of 16.7 ms). Post-repartition
   hardware measurement (`Arcade-Psikyo_20260867`, Gunbird attract, dbg_overlay row 215,
   two readings ~65 s apart both stable at the same value): `sp_render_max` = **789,066
   clk (8.6 ms) — up 29.3%**, not down. Not yet root-caused, but `rtl/memory/sdram/
   sdram.sv:177-216` shows the underlying single physical SDRAM chip's 3-port arbitration
   is FIXED-PRIORITY (port0 always preempts port1, which always preempts port2) — NOT
   round-robin/fair-share. Both before and after the repartition, tilemap traffic sits at
   higher physical priority than sprite traffic, so priority ordering alone doesn't obviously
   explain a regression (sprite was already lowest-priority before) — but merging both
   tilemap layers onto ONE arbitrated, highest-priority port (via `sdram_arbiter2`, which
   serializes what used to be two independently-scheduled streams into one) is a plausible
   contributor worth checking with a controlled sim measurement (real combined L0+L1+sprite
   traffic through `sim/`) rather than more noisy hardware attract-mode sampling. Also worth
   noting: this board's SDRAM is a SINGLE physical chip (`sdram` `mem_ctrl`, one instance,
   one set of `SDRAM_*` pins) with 3 logical/time-multiplexed ports arbitrated onto it — "port"
   here is not a second physical chip, so the original framing of this task ("use more chips
   in parallel") may not be achievable on this hardware; what's actually available to tune is
   which logical port each client sits behind and in what physical-priority slot, not genuine
   parallel bandwidth. Screenshots: `debug/sdramperf_gunbird_1.png`, `debug/sdramperf_gunbird_2.png`.
   NOT resolved — do not treat the re-partition as a completed fix. Options for whoever
   picks this up next: (a) swap which port tilemap vs. sprite sit behind and re-measure,
   (b) revert to the pre-repartition port assignment now that the granule cache alone may
   already have helped, (c) simulate the three traffic patterns together for a controlled,
   reproducible before/after instead of relying on a monotonic peak-since-boot hardware
   counter sampled at different, uncontrolled points in an attract loop.

   **Update 2026-08-29 (later same session):** found and fixed an unrelated but
   compounding bug surfaced by the same re-partition: Port 1's dedicated sprite-gfxrom
   connection wired the HELD-until-valid `gfxrom_req` straight into `sdram_phy`, whose
   `req` input is a one-shot PULSE contract every other consumer reaches only through an
   arbiter — causing sprite reads to silently return the previous transaction's stale
   data under contention (matches the "corrupted/wobbly sprites" symptom reported after
   the repartition). Fixed with a single-client pulse shim (`SP_IDLE`/`SP_ISSUE`/
   `SP_WAIT` in `rtl/memory/psikyo_sdram_top.sv`, commit `4d7e520`), covered by a new
   regression in `tb_psikyo_sdram_top.sv`. This fixes sprite/tilemap data corruption, not
   the render-time regression measured above, which remains open.
6. **Only then: add the remaining games** — Strikers 1945 and Tengai (Phase 2 boards:
   PIC protection FSM + the from-scratch YMF278B core, see the phase plan above).
