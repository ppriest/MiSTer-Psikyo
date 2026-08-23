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

## Progress (kept current — last updated 2026-08-23)

**Phase 0 — CPU spike: complete.** TG68K.C vendored, boots and executes 68020-mode code correctly
in ModelSim, synthesizes/fits cleanly on real Cyclone V (2,788/41,910 ALMs).

**Phase 1 — SH201B/KA302C hardware (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road): RTL
complete for sngkace-layout boards, real hardware bring-up underway.** Branch `phase1-sh201b-ka302c`.

Built and verified (ModelSim + real Quartus synthesis, each with its own testbench — see git
history for individual commits):

- Memory map (`docs/phase1_memory_map.md`), video engine design (`docs/phase1_video_engine.md`).
- Tilemap engine (`tilemap_line_engine.sv` + combinational stages) and zoom sprite engine
  (`sprite_render_engine.sv`, `sprite_frame_buffer.sv`, `sprite_display_list_walker.sv`, etc.) —
  full display-list walk → attribute fetch → zoom/position → spritelut → gfx fetch → pixel write
  pipeline, double-buffered.
- Compositor (`compositor.sv`) — resolves both tilemap layers + sprite frame buffer into palette
  index and xRGB_555, matching MAME's priority/transparent-pen/backdrop rules.
- Sound subsystem: T80 (Z80) + jt10 (YM2610) vendored; `sound_cpu_sngkace.sv`/
  `sound_cpu_gunbird.sv` wrap T80 against each board's real memory/IO map with verified req/valid
  ROM timing (see LESSONS_LEARNED.md's T80 section). jt10's SSG (jt49) channel verified as a real
  audio-domain functional test. **Not yet done**: FM channel + ADPCM-A/B verification, and jt10
  itself is not wired into the sound CPU's YM I/O bus yet (`ym_din` tied to 0).
- `.mra` files done for all 4 Phase 1 parent games + every MAME clone set (`releases/`,
  `releases/_alternatives/`), built directly from each game's `ROM_START`/`INPUT_PORTS_START`
  blocks, using the finalized SDRAM address map and generic DIP status-bit convention
  (`dsw_in = status[47:16]`).
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
  always read `output_files/Psikyo.sta.summary`, never trust "Fitter was successful". Ships with `BOARD_GUNBIRD` fixed to `1'b0` (sngkace
  layout only); a gunbird/btlkroad build needs its own top-level parameter value.

**Real hardware bring-up: CPU confirmed booting and fetching ROM on the DE10-nano
(2026-08-22).** First hardware test failed silently (misplaced `.rbf`, a deployment issue not an
RTL bug — see LESSONS_LEARNED.md). After fixing that, the screen stayed black; root-caused via a
VGA-color-override debug build to a genuine, two-part Quartus synthesis bug in TG68K.vhd's
RESET/HALT open-collector handling (Quartus resolves the shared tri-state net as a broken selector
instead of true wired-AND — full writeup in LESSONS_LEARNED.md's TG68K.C section). Fixed with a new
`ext_force_run`/`effective_reset` signal pair in `TG68K.vhd`, wired from `maincpu.sv`. Confirmed
working via a sequence of debug-color hardware screenshots (cyan → red → green, each color proving
one more stage of the fix), then verified clean after removing all debug instrumentation: full
ModelSim regression re-passes (`tb_maincpu`, `tb_psikyo_core_smoke`, `tb_psikyo_core`,
`tb_psikyo_top` all PASS) and a fresh hardware rebuild/deploy is in progress to confirm on real
silicon with the actual game screen (not a debug color).

**Root cause of the "CPU boots but reads garbage" symptom found (2026-08-23): the design did not
close timing.** After the RESET/HALT fix the CPU ran on real hardware but never wrote video or work
RAM, while an identical real-ROM ModelSim run wrote work RAM within microseconds. Six rounds of
VGA-colour-override debug builds narrowed it to ROM words read back wrong ~51% of the time,
deterministically and *identically* at two different SDRAM_CLK phase shifts. That pointed at the
memory interface, and a full audit cleared it: all 38 SDRAM pin assignments verified identical
across `Psikyo.qsf`, the vendor `sys/sys.tcl`, and the post-fit `.pin` file; `SDRAM_DQ` confirmed
fully IOE-registered (16/16 in/out/OE); `sdram.sv`'s burst-4 adaptation reviewed against upstream
and found sound.

The actual cause was in `output_files/Psikyo.sta.summary`, which nothing in the build flow forces
you to read: **the `clk_sys` domain had −8.879 ns setup slack and −21,031 ns TNS, with an Fmax of
48.74 MHz against an 85.909091 MHz clock.** Every one of the 50 worst-slack paths in the whole
design was inside `TG68KdotC_Kernel` — nothing else failed timing at all. TG68K.C was free-running
at `clk_sys` because the architecture has no clock-enable input of its own, which was both 5.4x the
real board's 16 MHz 68EC020 and far beyond what the core can physically close.

Fixed by adding an `ext_clkena` port to `TG68K.vhd` that gates *every* clocked process in the
architecture (not just the kernel — the bus state machine's one-cycle `clkena_e` pulse would
otherwise be lost on cycles the gated kernel sleeps through), driven from `maincpu.sv` by an exact
Bresenham 176/945 enable = 16.000 MHz. This required latching the ROM read path (`rom_data_l`/
`rom_ready` in `maincpu.sv`), because `sdram_narrow_bridge` returns a one-cycle `valid` with
combinational data and a CPU stepping every ~5.4 cycles would miss it. `Psikyo.sdc` gained matching
`set_multicycle_path` constraints. Validated in ModelSim against the real `samuraia` ROM: same
first work-RAM write (`addr=c07e`), same vblank-IRQ time, with the CPU proportionally further back
in its program — exactly the expected 16 MHz behaviour. Full writeup in LESSONS_LEARNED.md's new
"Static timing analysis" section.

**ROM download never reached SDRAM (found and fixed 2026-08-23).** MiSTer holds core RESET
asserted for the ENTIRE ROM download; Psikyo.sv folds that into `reset` and psikyo_top passed it
into the SDRAM backend, pinning sdram_download's FSM in D_IDLE. Zero write commands ever reached
the chip while the HPS delivered all 0xE00000 bytes. Fixed with
`sdram_reset = reset & ~ioctl_download`, confirmed at the pins (CMD_WRITE 0x000 -> 0xE00); the
CPU's reset vector now reads SP=0xFFFF8000 PC=0x00000400, matching MAME. Note upstream
`sdram.v` has no reset port at all by design — this project's wrappers added one.

**Core still does not run the game.** With correct ROM contents the CPU reads its reset vector and
then, without executing at 0x400, takes bus error -> illegal instruction -> F-line. The next step
is a planned rewrite of `rtl/cpu/maincpu.sv` to drive `TG68KdotC_Kernel` directly at a 16 MHz
clock enable instead of rate-limiting the `TG68K.vhd` async-bus wrapper — see
**`docs/maincpu_kernel_rewrite.md`** for the full plan, the reference implementation
(mist-devel/plus_too's tg68k.v), and the list of verified fixes that must survive it.

`scripts/mister_hw_test.py` — a maintained deploy/launch/screenshot automation tool for this
hardware-bring-up loop (SCP the `.rbf`, launch a `.mra` via the MiSTer Remote API, pull a
screenshot back) — see the script's own docstring/`--help` for usage.

Every RTL module has been verified in ModelSim against an independently-computed reference
(exhaustively or near-exhaustively over its realistic input domain) — see individual module
headers and commit messages for verification counts.

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

**Phase 1 — SH201B/KA302C hardware (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road): RTL
complete, hardware bring-up underway.** Exit criteria: all three games booting, correct sprite
zoom/priority, correct tilemap size-switching and row-scroll, working `.mra` files for each region
variant.

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

**Release artifacts**: generated per-game `.mra` files plus the compiled `.rbf`, named
`Arcade-Psikyo_{date}.rbf`, committed into `releases/`.

## Open items / assumptions to revisit

- **Pause function, mapped to a controller button** — suspend the core (freeze `clk_sys`/`ce_pix`
  gating or hold everything in a frozen state without losing it) so a single frame can be held
  still on screen. Standard practice for bring-up — makes it far easier to capture a transient
  visual glitch that would otherwise flash past in one frame. Not yet designed — needs a real
  mechanism (likely gating `ce_pix`/frame-buffer swap rather than the CPU clock itself, so audio
  doesn't also need to freeze/resume cleanly) and a status-bit/OSD or joystick-button mapping.
- **No original Psikyo PCB** (confirmed) — MAME's own emulated output is the accuracy target,
  including its acknowledged uncertainties (layer-enable bits, sprite zoom curve, tilemap
  size-switch behavior all flagged "not quite right" in the driver itself).
  DE10-nano hardware bring-up IS available and now underway (see Progress above) — a MiSTer is
  set up with SSH access and (as of 2026-08-21) a USB Blaster II-style JTAG cable, though JTAG
  itself isn't yet reachable from this dev environment (`jtagconfig` reports no hardware detected
  here — recheck before assuming JTAG programming/probing is usable from this machine). See
  LESSONS_LEARNED.md's "Real hardware bring-up" section for the working SSH/SCP/Remote-API deploy
  flow already in use, and danifunker/lbmactwo_MiSTer's
  `docs/MISTER_HARDWARE_DEBUGGING.md` for JTAG-specific technique (ISSP probing, JTAG chain
  addressing) once that path opens up.
- **YMF278B de-risking spike** should probably happen early (maybe alongside/soon after Phase 1
  wraps) rather than right before Phase 2 — worth deciding scheduling once Phase 1 hardware
  bring-up is further along.
- **Sprite frame-renderer throughput is unbudgeted at the whole-frame/whole-game level.** One real
  single-sprite data point exists (`sim/port2_sdram_tb/`: 514 cycles alone, 736 under sustained
  contention) but extrapolating across a worst-case display list (1023 entries × up to 64
  sub-tiles/entry) hasn't been checked against real per-game sprite/sub-tile counts. Revisit once
  real per-game numbers are known.
- **samuraia/sngkace ADPCM-A sample ROM needs a bit 6/7 swap not yet implemented anywhere.**
  MAME's `init_sngkace()` applies `out[7]=in[6], out[6]=in[7]` to the `ymsnd:adpcma` region for
  samuraia/samuraiak/sngkace/sngkacea ONLY (not gunbird/btlkroad despite identical sound hardware).
  Real ROM-mastering artifact, can't be expressed in `.mra` (byte-level only), needs a per-game
  select signal. Full writeup in `docs/phase1_memory_map.md`; belongs alongside
  `sdram_download.sv` as a download-time fixup.
- **Timing closure not yet final.** First full place-and-route produces a working `.sof`/`.rbf`
  but had residual negative setup slack after fixing the dominant offender (a synthesized mod-768
  divider, see LESSONS_LEARNED.md). Remaining gap is a smaller arithmetic path in
  `sprite_record_decode.sv`/`sprite_render_engine.sv` — needs a real pipelining pass, not yet
  attempted since it risks disturbing the render engine's per-column state machine timing.

## Next steps

1. **Confirm the RESET/HALT fix on real hardware with debug instrumentation fully removed** (in
   progress — see Progress above) and commit that body of work.
2. A `BOARD_GUNBIRD(1'b1)` build variant for gunbird/btlkroad (currently `Psikyo.sv` fixes
   `BOARD_GUNBIRD` to `1'b0`/sngkace only).
3. Sound subsystem: jt10 FM channel + ADPCM-A/B ROM interface verification (audio-domain, not
   just compile-clean — tracked in `rtl/sound/jt10/PROVENANCE.md`, including an unresolved
   `jt10_acc.v` port-width warning), then wire jt10 into the sound CPU's YM I/O bus and apply the
   samuraia/sngkace ADPCM-A bit 6/7 swap during ROM download.
4. Timing closure pass on `sprite_record_decode.sv`/`sprite_render_engine.sv` (see Open items).
5. CRT_Offset module and hiscore.v — later-stage/polish, not needed for initial bring-up.
6. Continue DE10-nano bring-up now that the CPU boots: verify actual gameplay/graphics rendering
   correctness (not just "boots"), design/implement the Pause feature (see Open items).
