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

## Phase 1 integration (`rtl/cpu/maincpu.sv`): uninitialized-signal crash, found and fixed

Building the real address-decode/DTACK wrapper (`rtl/cpu/maincpu.sv`) against a genuine
program (not the Phase 0 spike's short, deliberate 4-instruction test) surfaced a severe issue
the spike never could: ModelSim crashed outright (SIGSEGV, then cascading multi-GB memory
allocation failures) after a sustained run, even reduced to the sharpest possible isolation
(pure VHDL, the spike's own trivial zero-wait DTACK, a constant-NOP or tight `BRA.S`-self-loop
ROM, no address decode, no RAM regions at all).

Root cause, confirmed by instrumented log analysis (not guessed): the crashing runs' `'X'`-in-
arithmetic-operand ALU warnings were not triggered by anything at the eventual crash timestamp
— they occurred continuously, on every single clock edge, starting from simulation time 0 and
never clearing, even well after reset completed. This matches a publicly reported upstream
issue (github.com/TobiFlex/TG68K.C/issues/21, "uninitialised signals in arithmetic") whose
reporter identified the same class of signal and whose thread confirms the maintainer's
position: real hardware zero-power-ups these registers, so upstream deliberately doesn't add
simulation-only initializers ("initialization will require more logic").

Fix applied here (simulation-fidelity only, not an algorithm change — matches
`rtl/memory/sdram/PROVENANCE.md`'s precedent for the same class of fix): explicit `:= '0'` /
`:= (others => '0')` initializers added to every previously-uninitialized `std_logic`/
`std_logic_vector` signal declaration in both `TG68K_ALU.vhd` (rotate/divide/barrel-shift/
bit-field internals — matches the reported issue's own subset almost exactly) and
`TG68KdotC_Kernel.vhd` (110 signals — the microcode/state-machine layer, which also needed the
same treatment; the public issue only covered the ALU, but the same crash pattern persisted
after fixing just that, so the kernel's own declarations were audited and fixed the same way).
Confirmed load-bearing, not just plausible: reverting either file's initializers reproduces the
crash; with both applied, every isolation test (pure VHDL and mixed SV/VHDL) runs the same
40,000-cycle workload cleanly in ~1-2 seconds, matching the Phase 0 spike's own baseline.

Once past the crash, `sim/maincpu_tb/tb_maincpu.sv`'s Case 1 (real ROM req/valid fetch, all 6
BRAM regions -- sprite RAM/palette/tilemap VRAM x2/video regs/work RAM -- the 32-bit input-port
read, and the sound-latch write) passed cleanly on the first real run: the address decode and
DTACK generation logic itself (`rtl/cpu/maincpu.sv`, built the same way
`rtl/sound/sound_cpu_sngkace.sv`'s req/valid conversion was) is verified correct.

**Still open**: Case 2 (the held-autovectored level-4 vblank IRQ) does not yet pass. Signal
tracing confirmed the interrupt request, recognition, IPL encoding, and the IACK bus cycle
itself (address `0xFFFFFFF8`, correctly encoding level 4) all execute correctly, and the CPU
correctly computes the vector *offset* to push into the exception frame's format word
(`0x0070`, matching vector 28 = level 4's real autovector number — vector 24 is "Spurious
Interrupt", a different exception entirely; levels 1-7 map to vectors 25-31, a real arithmetic
mistake in this test's first version, since fixed). But the CPU's actual vector-table *fetch*
address is `0x00000000`, not `0x70` — meaning the offset computed for the stack-frame bookkeeping
word and the address actually used to fetch the handler pointer are evidently two separate
code paths in the kernel, and only one is currently correct. Not yet root-caused past that
point; needs a further, narrower dig into `TG68KdotC_Kernel.vhd`'s exception/vector-fetch
microcode (search for where `trap_vector`/vector vs. VBR is combined into a memory address,
distinct from where `IPL_vec`/the format-word offset is computed) rather than the
uninitialized-signal class of fix that resolved the crash. Does not block using
`rtl/cpu/maincpu.sv` for non-interrupt-driven top-level integration work in the meantime.
