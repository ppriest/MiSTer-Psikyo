# MiSTer framework notes

Distilled from the official developer docs
(https://mister-devel.github.io/MkDocs_MiSTer/developer/) plus verified reference cores.
Written 2026-08-23 after several hours were spent re-deriving parts of this empirically --
**read this before inventing anything in these areas.**

Each item is marked as **[doc]** (from the official documentation), **[core]** (verified against
a shipped MiSTer-devel core), or **[empirical]** (established by measurement here and NOT
confirmed by documentation).

## CONF_STR and the status register

- **[doc]** `status[0]` is reserved as **Soft Reset**. Never use it for anything else.
- **[doc]** "Only one option can occupy a status bit, so this is important." Collisions are
  silent -- the symptom is an option that simply does not respond.
- **[doc]** Classic syntax addresses **bits 0-63 only**, as two 32-bit groups:
  `O{Index}` = upper group, `o{Index}` (lowercase) = lower group, i.e. index + 32. Index
  characters are `0-9` and `A-V` (32 positions per group).
- **[doc]** Bracket form is `O{Index1}[{Index2}],{Name},{Options...}` -- "First and second index
  are the range of bits that will be set in the status register."
- **[doc]** Pages: `P{#},{Title}` declares a page; prefix options with `P{#}`. The prefix goes
  before `O#` but after conditionals like `d#`.
- **[empirical]** An `.mra` with N `<switches>` bytes consumes **8*N bits starting at
  status[16]**. This project's `.mra` declares five bytes (`FF,FF,FD,FF,FF`), so the DIP
  mechanism owns **status[55:16]** -- even though the core only reads `dsw_in = status[47:16]`.
  Debug bits placed at 48-55 were contested by it and did not respond.
- **Practical allocation rule for this project:** put non-DIP options in **status[63:56]** --
  above the MRA switch range and inside the documented 0-63 window.
- Validate bit assignments with **https://agg23.github.io/mister-config/** (paste the CONF_STR,
  see which bits each option claims) rather than reasoning about ranges by hand.

## Per-core settings file

- **[empirical]** `/media/fat/config/<setname>.CFG` is 16 bytes = the 128-bit `status` word,
  little-endian (byte N holds status[8N+7 : 8N]). Writing it over SSH and relaunching applies
  the settings, which allows fully automated OSD control with no menu navigation -- very useful
  for hardware debugging. NOT documented; verified by toggling a known bit and observing the
  effect. Treat higher bits with suspicion given the 0-63 rule above.

## SDRAM and ROM download

- **[core]** `Arcade-IremM90_MiSTer` is the reference for the standard pattern:
  ```verilog
  wire reset = RESET | status[0] | buttons[1] | rom_load_busy;   // the CORE is reset during load
  sdram sdram (.*, .doRefresh(1), .init(~pll_locked), .clk(clk_ram), ...); // NO reset input
  ```
- **The invariant: MiSTer holds core RESET for the ENTIRE ROM download, so nothing in the memory
  write path may be reset by it.** Upstream `sdram.v` has no reset port at all, by design.
  This project's own wrappers added one, which silently discarded every downloaded byte -- zero
  `CMD_WRITE` commands ever reached the chip. See `docs/LESSONS_LEARNED.md`.
- **[core]** The download path is a separate loader writing through a multiplexed SDRAM channel,
  with a `rom_load_busy` flag gating CPU access -- not the CPU's own port.

## Video

- **[core]** Arcade cores normally instantiate **`arcade_video`** (`sys/arcade_video.v`), which
  wraps `video_mixer` (scandoubler, gamma) and `video_freak` (aspect ratio / crop), and handles
  rotation for vertical games.
- **This core does NOT use it** -- `Psikyo.sv` drives `VGA_R/G/B`, `VGA_DE/HS/VS`, `CLK_VIDEO`
  and `CE_PIXEL` directly. That works (real graphics have been observed on hardware through this
  path) but forgoes scandoubler/gamma/aspect handling. `sys/arcade_video.v`, `video_freak.sv`
  and `video_mixer.sv` are all present and unused. Worth migrating to the standard path.

## Other developer pages worth reading before touching these areas

Porting Cores; Core Configuration String; Top-level of Cores (emu, hps_io, video_freak,
video_mixer, arcade_video); Useful Snippets; Savestates; Core Names; MRA Setnames; Arcade ROMs
and MRA Files; **Debugging (USB Blaster)** -- directly relevant once the JTAG probe arrives;
Developer Journeys; Template Core; Tips and Guidelines.
