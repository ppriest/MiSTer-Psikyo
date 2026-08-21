# T80 provenance

Vendored from https://github.com/MiSTer-devel/T80, commit `830fd0315f0af5cdbcb0e703f1cea3ce4e91f538`
(2021-03-31), for use as the sound-CPU core (Z80 on SH201B/KA302C; LZ8420M on SH403/SH404 is
expected to be T80-compatible, per docs/ROADMAP.md's component reuse map -- not yet confirmed,
Phase 2 concern).

License: 3-clause BSD-style (stated in each file's header, no separate LICENSE file upstream).
Original core copyright (c) 2001-2002 Daniel Wallner <jesus@opencores.org>; maintained since by
MikeJ (fpgaarcade.com) and the MiSTer-devel community (Sorgelig, TobiFlex, Bruno Duarte Gouveia).
Permissive, no copyleft obligation -- redistribution/synthesis permitted with attribution.

`T80se.vhd` is the top-level this project will instantiate: the standard synchronous wrapper
exposing the classic Z80 bus (`M1_n`/`MREQ_n`/`IORQ_n`/`RD_n`/`WR_n`/`RFSH_n`/`HALT_n`, 16-bit
`A`, 8-bit `DI`/`DO`), same interface convention nearly every MiSTer arcade core built around a
Z80 sound CPU uses. `Mode` generic: `0` = Z80 (what this project needs), `1` = Fast Z80, `2` =
8080, `3` = Game Boy.

Files kept as vendored (`T80.qip` lists the full compile set): `GBse.vhd`, `T80.vhd`, `T80a.vhd`,
`T80as.vhd`, `T80pa.vhd`, `T80s.vhd`, `T80se.vhd`, `T80sed.vhd`, `T8080se.vhd`, `T80_ALU.vhd`,
`T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`. Only `T80se.vhd` (plus its dependencies:
`T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`) is actually needed for
this project; the other top-levels (`GBse`, `T8080se`, `T80a`, `T80as`, `T80pa`, `T80s`,
`T80sed`) are kept vendored anyway rather than pruned, matching `T80.qip`'s own file set --
avoids having to re-derive which files are truly load-bearing if a later phase needs a different
top-level variant.

Much lower risk than TG68K.C (`rtl/cpu/tg68k/PROVENANCE.md`): T80 is the de facto standard Z80
core across the MiSTer-devel arcade ecosystem (embedded directly in dozens of cores per
docs/ROADMAP.md's survey), unlike TG68K.C being the *only* viable open 68020 option. Still
worth an independent boot spike before trusting it, same discipline as Phase 0.

## Status

- [x] Source vendored
- [x] Compiles under ModelSim-Altera 10.5b (`sim/t80_spike/`), clean 0 errors (one pre-existing
      upstream width-mismatch warning in `T80.vhd` line 685, an `and` of a 9-bit and a 4-bit
      operand -- not introduced by this project, not investigated further given T80's low prior
      risk, see below)
- [x] Boots and executes a small test program in simulation (`sim/t80_spike/tb_t80_boot.vhd`):
      fetches from address 0 (Z80 has no reset vector, unlike 68k), executes `LD A,0x42`,
      `LD (0x8000),A` (memory write), `OUT (0x00),A` (I/O write), `HALT` -- all four checked
      against expected values, PASS. Exercises opcode fetch, immediate fetch, a memory write
      cycle, and an I/O write cycle -- the classic bus protocol paths this project's actual
      memory-map wiring will depend on.
- [ ] Synthesizes/fits on the real Cyclone V (likely unnecessary as a standalone check given
      how widely this core is already proven on this exact FPGA family across other MiSTer
      cores -- revisit once the full sound subsystem is integrated instead)

**Simulation quirk, not a design issue**: `vsim -c -do "run -all; quit -f"` ran the simulation
to completion and printed PASS at 2040ns, but `quit -f` did not cleanly terminate the VHDL-only
session afterward -- the process sat idle (0% CPU) rather than exiting, needing a manual kill.
Every other testbench in this project (Verilog/SystemVerilog DUTs) has exited cleanly with the
same invocation; this may be specific to a VHDL top-level ending its process with a bare `wait;`.
Not investigated further since the actual simulation result is what matters and was captured
before the hang -- worth remembering if a future VHDL-only testbench run appears to hang: check
whether it already printed PASS/FAIL before assuming something is actually stuck.
