# Psikyo (PS3/PS4/PS5/PS6) MiSTer Core — Roadmap

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
get copied over to `_Arcade/cores` and `_Meathax` once builds are ready, the way your other cores
already are.

## Open items / assumptions to revisit

- **No real hardware access** (confirmed) — this project is built purely from MAME source +
  datasheets/chip documentation, with no PCB available for logic-analyzer ground-truth. That makes
  **MAME's own emulated output the de facto accuracy target**, including its acknowledged
  uncertainties: the driver's own comments flag the layer-enable bits, sprite zoom curve, and
  tilemap size-switch behavior as "not quite right" / unverified, and without a board there's no
  way to resolve those beyond matching MAME's behavior as closely as possible. Worth remembering
  this ceiling exists rather than chasing precision MAME itself doesn't have.
- **YMF278B de-risking spike** should probably happen early (maybe alongside Phase 0) rather than
  right before Phase 2, given it's the other component with no existing shortcut — worth deciding
  scheduling once Phase 1 is underway and its actual cost is clearer.

## Next steps

1. Create `D:\Mister-Psikyo`, `git init` it, and seed it from **MiSTer-devel/Template_MiSTer**;
   configure the Quartus 17.x project for the DE10-nano, cross-checking arcade-specific wiring
   (MRA/ROM loader, DIP/status bits, video pipeline shape) against Raiden_MiSTer/Toaplan2.
2. Run the Phase 0 TG68K.C spike.
3. Begin Phase 1 RTL: memory map (`psikyo_map` in `psikyo.h`/`psikyo.cpp`) → SDRAM layout → video
   engine → sound subsystem, in that order.
