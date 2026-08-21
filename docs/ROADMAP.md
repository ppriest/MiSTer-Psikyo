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

## Progress (kept current — last updated 2026-08-22, commit `e0bf109`)

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
- Not yet started: SDRAM tile/sprite/sound ROM banking, top-level integration against
  Template_MiSTer (CRT_Offset, DIP/control mapping, hiscore.v — see "Component reuse map"
  above), `.mra` files.

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
- **YMF278B de-risking spike** should probably happen early (maybe alongside Phase 0) rather than
  right before Phase 2, given it's the other component with no existing shortcut — worth deciding
  scheduling once Phase 1 is underway and its actual cost is clearer.
- **Sprite frame-renderer throughput is still unbudgeted, now that `sprite_render_engine` exists
  and its actual per-stage cycle costs are known.** Rough math from the RTL as built: one
  sub-tile costs roughly (LUT round-trip) + `dst_size_y` × (gfx ROM round-trip + `dst_size_x`
  column cycles) — at full zoom (16×16) with, say, a 4-cycle ROM round-trip, that's on the order
  of ~330 cycles/sub-tile. Worst case (1023 display-list entries, each an 8×8-tile sprite = 64
  sub-tiles) would be ~21M cycles — far beyond one frame period at any realistic clock. Real
  games are extremely unlikely to hit that theoretical worst case, but this still hasn't been
  checked against actual per-game sprite/sub-tile counts (no MAME frame trace pulled yet).
  Revisit once real per-game numbers are known — may need a per-sub-tile cycle budget/drop-excess
  bound, a faster render clock, or reduced ROM latency (e.g. wider on-chip gfx ROM bursts).

## Next steps

See "Progress" above for current status. Immediate next items, in order:

1. Sound subsystem, continued: a real jt10 verification pass (audio-domain, not just
   compile-clean — see `rtl/sound/jt10/PROVENANCE.md`) before actually wiring it into either
   sound CPU wrapper's YM I/O chip-select bus; and ADPCM-A/B ROM banking once jt10 itself is
   trusted.
2. SDRAM tile/sprite/sound ROM banking and top-level integration against Template_MiSTer,
   including the CRT_Offset module, DIP/status-bit + control mapping, and (later-stage/polish,
   not needed for initial bring-up) hiscore.v — see "Component reuse map" above.
3. `.mra` files for sngkace/gunbird/btlkroad region variants; DE10-nano black-box bring-up.
