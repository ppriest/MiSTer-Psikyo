# TG68K.C provenance

Vendored from https://github.com/TobiFlex/TG68K.C, commit `ade33e396a1e647c2de9daf71ff9d5b3979639b2`
(2025-03-24), for use as the 68EC020 main CPU core.

License: LGPLv3+ (stated in each file's header, no separate LICENSE file upstream).
Copyright (c) Tobias Gubener <tobiflex@opencores.org>.

`TG68K.vhd` exposes a `CPU` generic selecting core mode: `"00"` = 68000, `"01"` = 68010,
`"11"` = 68020. We need `"11"`.

## Known risk (from upstream README, both languages)

> The core does not value cycle accuracy. The core saves the FPGA resources with a good
> execution speed.

This is a real tension with this project's verification approach (matching MAME's emulated
behavior as the accuracy bar — see docs/ROADMAP.md). Most arcade titles don't depend on strict
CPU bus-cycle timing, but this is the first thing to suspect if Phase 1 games run logically
correct but glitch on timing-sensitive effects (raster splits, tight interrupt-driven audio
sync, etc).

## Phase 0 status

- [x] Source vendored
- [x] Compiles under ModelSim-Altera 10.5b (bundled with Quartus 17.0.2 Lite at
      `C:\intelFPGA_lite\17.0\modelsim_ase`) — clean, 0 errors/0 warnings
      (`sim/tg68k_spike/`)
- [x] Boots and executes a test program in simulation, in **68020 mode** (`CPU => "11"`),
      over the classic async bus wrapper (AS/UDS/LDS/RW/DTACK): reset vector fetch (SSP/PC)
      and sequential instruction fetch verified correct against the trace
      (`sim/tg68k_spike/tb_tg68k_boot.vhd`). See "Debugging notes" below for two false
      alarms hit along the way and how they were resolved.
- [x] Exercised actual 68020-only additions over base 68000: **MULU.L** (32x32→32,
      `70000*2=140000=0x000222E0`), **DIVU.L** (32/32→32, `100000/7=14285=0x000037CD`),
      68020-only **scaled-index addressing** `(d8,An,Xn.L*4)` (table lookup), and **BFEXTU**
      bitfield extract — all four produced mathematically correct results
      (`sim/tg68k_spike/test020.s`, assembled with vasm — see "Debugging notes" item 3).
- [x] Synthesizes and fits cleanly under Quartus 17.0.2 Lite for the DE10-nano's actual
      Cyclone V (5CSEBA6U23I7) — standalone check, TG68K.C alone with no other project
      logic (`rtl/cpu/tg68k/synth_check/`, same FAMILY/DEVICE/package/pin-count/speed-grade
      settings as `sys/sys.tcl`). Analysis & Synthesis: 0 errors, 4 warnings (RAM
      pass-through inference for the register file, one connectivity-check note — both
      benign). Fitter: 0 errors, 5 warnings (all expected for a standalone check with no
      pin assignments — "no exact pin location" etc.). Final placed utilization:
      **2,788 / 41,910 ALMs (7%)**, 1,378 registers, 2 RAM blocks (<1%, just the register
      file), 6 / 112 DSP blocks (5%, the hardware multiplier). Comfortably modest footprint
      — leaves the overwhelming majority of the device for the video engine, sound chips,
      and SDRAM controller still to come.

## Phase 0 complete

All four planned checks passed: vendored + compiles, boots/executes correctly (including
genuine 68020-only opcodes: MULU.L, DIVU.L, scaled-index addressing, BFEXTU), and
synthesizes + fits on the real target device at a modest 7% ALM utilization. TG68K.C is a
green light for Phase 1. The one carried-forward risk is the upstream "not cycle accurate"
disclaimer noted above — nothing found so far contradicts it, but nothing done so far tests
for it either (the spike checks functional correctness, not bus timing fidelity against
real 68EC020 silicon). Watch for it if Phase 1 games run logically correct but glitch on
timing-sensitive effects.

## Debugging notes (for whoever touches this testbench next)

Three false alarms while bringing up `sim/tg68k_spike/`, all worth knowing about before
extending it further:

1. **Reset never actually asserted.** `TG68K.vhd` derives the kernel's active-low reset as
   `cpu1reset <= RESET OR HALT`. Driving only the top-level `RESET` signal low (leaving `HALT`
   released) resolves that OR to `'1'` — i.e. NOT reset — so the CPU powered up with fully
   undefined internal state and produced continuous `'X'` propagation from cycle 1. Fix: drive
   `RESET` and `HALT` low together for the power-on pulse.
2. **Hand-encoded `MOVE.L D0,$2000` (as `0x2380`) wrote to the wrong address** (0x8/0xA
   instead of 0x2000/0x2002), identically in both CPU=00 and CPU=11 modes. This looked like a
   core bug at first, but the dual-mode reproduction doesn't actually prove that: absolute-long
   addressing isn't gated by any of TG68K.C's 68020-specific generics, so a bad opcode encoding
   would misbehave identically in every mode too — which it did. The actual root cause, found
   once vasm was available to cross-check (item 3): `0x2380` was simply a hand-arithmetic
   mistake in grouping the destination-mode bits (the correct encoding is `0x23C0`); it had
   nothing to do with 68020 mode or the core at all. Isolated at the time with `CLR.L
   $00002000` (a single-operand instruction using a simpler EA field) — it wrote to the correct
   address, which was enough to confirm the core's absolute-long EA computation was fine and
   the bug was ours.
3. **Stopped hand-encoding 68k machine code entirely after two near-misses above.** Built vasm
   (m68k, Motorola syntax) from official source instead — see `tools/README.md` and
   `scripts/fetch_build_vasm.sh` for why it isn't vendored (license) and how to reproduce the
   build. `sim/tg68k_spike/gen_rom_vhdl.py` converts a `vasm -Fbin` output directly into VHDL
   `mem_v` initialization lines, so there's no manual transcription step left anywhere in this
   testbench's ROM contents. Cross-checking vasm's own output for `move.l d0,$2000.l`
   (`0x23C0`) against the `0x2380` used in false alarm #2 is what actually found that mistake.

General technique note: report-based bus tracing in a process with bare `sensitivity-list`/
`rising_edge(clk)` can catch signals mid-delta-cycle-transition and show misleading values.
Sampling via `wait until rising_edge(clk); wait for 1 ns;` (small settle delay after the edge)
before reading any signal was the reliable fix, used throughout this testbench.
