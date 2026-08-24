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
- **[empirical]** An `.mra` with N `<switches>` bytes consumes 8*N bits starting at
  **status[16]**: byte0 -> `status[23:16]`, byte1 -> `status[31:24]`, and so on. This project's
  `.mra` files declare three bytes, so the DIP mechanism owns `status[39:16]`.
- **[doc+empirical]** MAME's psikyo DSW port puts every DIP in the UPPER half of the 32-bit long
  at `$C00004` and the region jumper in its low byte. `Psikyo.sv` therefore feeds
  `dsw_in = {status[31:16], 8'hFF, status[39:32]}`. An earlier `status[47:16]` mapping put every
  DIP 16 bits low, in the half MAME defines as unused, so no OSD DIP did anything and Service
  Mode was stuck on.
- **Allocation in use here:** DIPs `status[39:16]`; render-disable and sprite-swap debug bits
  `status[43:40]`; scandoubler FX `status[46:44]`; rotation/flip `status[49:47]`; tracer controls
  `status[63:56]`; aspect ratio `status[122:121]`.
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
  wraps `video_mixer` (scandoubler, gamma) and `video_freak` (aspect ratio / crop).
- This core now does. It previously drove `VGA_R/G/B`, `VGA_DE/HS/VS`, `CLK_VIDEO` and
  `CE_PIXEL` directly, which worked but gave up the scandoubler (so no 31 kHz CRT option),
  gamma, scanline effects and aspect handling — all of which were already compiled in via
  `sys/sys.qip` and simply never instantiated.
- **Rotation is a separate module.** `sys/screen_rotate.v` is not present in this tree; the copy
  in use is `rtl/video/screen_rotate_two.sv` (Sorgelig, GPL v2, taken from
  `Arcade-SKNS_MiSTer`). It is a TAP, not a filter: `VGA_*` still drive the analog output
  natively, while a rotated copy is written to DDRAM and `FB_*` points the HDMI scaler at it.
  It only honours `flip` when not rotating (`do_flip <= no_rotate && flip`), so rotation and
  180-degree flip are alternatives.
- The framework copy here exposes `FB_EN/FB_FORMAT/FB_BASE/FB_STRIDE/FB_VBL/FB_LL` and DDRAM,
  but has no `video_rotated` port; that output is left unconnected, as `Arcade-SKNS` also does.

## Other developer pages worth reading before touching these areas

Porting Cores; Core Configuration String; Top-level of Cores (emu, hps_io, video_freak,
video_mixer, arcade_video); Useful Snippets; Savestates; Core Names; MRA Setnames; Arcade ROMs
and MRA Files; **Debugging (USB Blaster)** -- directly relevant once the JTAG probe arrives;
Developer Journeys; Template Core; Tips and Guidelines.
