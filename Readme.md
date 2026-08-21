# Psikyo core for MiSTer

MiSTer FPGA core for the original Psikyo shooter arcade hardware (Samurai Aces/Sengoku Ace, Gun
Bird, Battle K-Road — SH201B/KA302C boards — with Strikers 1945/Tengai planned for a later
phase), built against Quartus 17.0.x for the DE10-nano.

**Status**: in active development, no releases yet. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for
the full design, current progress, and what's left before a bootable `.rbf` exists.

## ROMs

**This repository does not include, and will never include, any game ROMs.** No ROM files are
committed to this repo under any circumstances.

To run this core once it's usable, you are responsible for either dumping the ROMs from
genuine hardware you own, or otherwise obtaining them through means for which you hold
appropriate legal rights/licensing in your jurisdiction. Neither the MiSTer project nor this
core's author distributes, links to, or assists in acquiring ROM files.

## Source structure

This core follows the standard [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)
layout:

* `sys` — the MiSTer framework, as vendored from the template.
* `rtl` — this core's source.
* `releases` — compiled `.rbf` releases (`Arcade-Psikyo_YYYYMMDD.rbf`) and generated `.mra`
  files, once builds exist.
* `docs` — design documentation (memory map, video engine design, roadmap).
* `sim` — ModelSim testbenches for individual RTL modules.

Built and developed in Quartus Prime **17.0.2 Lite**, per MiSTer-devel convention for this FPGA.
