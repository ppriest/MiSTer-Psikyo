# Lessons Learned

Cross-cutting technical lessons from building this core — patterns, gotchas, and tool
behaviors likely to recur. Organized by topic, not chronology. For the blow-by-blow history of
*when* each of these was found, see git log / commit messages; per-component vendoring detail
lives in each module's own `PROVENANCE.md` (`rtl/cpu/tg68k/`, `rtl/memory/sdram/`,
`rtl/sound/jt10/`, `rtl/sound/jt49/`).

## Suspect your own changes and your integration first

- **Vendored cores and MiSTer's own infrastructure are battle-tested; on balance the bug is
  yours.** TG68K.C, T80, Sorgelig's `sdram.sv`, MRA/ROM loading, `hps_io`, `sys_top` ship in many
  working cores. On 2026-08-23 a full day went into suspecting, in order: SDRAM pin assignments
  (38/38 correct), SDRAM_CLK phase (irrelevant — identical output a quarter period apart), the
  burst-4 SDRAM controller (sound), the MRA interleave (correct — "fixed" wrongly, then reverted),
  and TG68K's exception microcode (a testbench bug). The real cause was integration glue this
  project wrote.
- **When a vendored module omits something obvious, that omission is usually deliberate.**
  Upstream `sdram.v` has **no reset port at all** — driven purely by `init` — precisely so a core
  reset cannot disturb memory. This project's wrappers added one, which is exactly what
  reintroduced the hazard below. Read the upstream design before overriding it.
- **Do not "fix" a loader or file format without hardware evidence it produces wrong bytes.** The
  `.mra` maincpu interleave was rewritten from `<interleave output="16">` with `map="01"/"10"` to
  `output="32"` with 4-digit maps, on the strength of a mental model that predicted a corrupt
  stack pointer. The 4-digit maps turned out to be **silently ignored** (proved by swapping them
  and getting byte-identical hardware output), and the original form was right all along. Every
  test that seemed to indict it had run against an SDRAM that was never written — garbage
  compared against garbage.

## MiSTer integration: ROM download and reset

- **MiSTer holds core `RESET` asserted for the ENTIRE ROM download.** Anything in the memory path
  that resets on `RESET` is therefore dead for the whole transfer. Here `Psikyo.sv` builds
  `reset = RESET | status[0] | buttons[1] | ~pll_locked` and `psikyo_top` passed it into the SDRAM
  backend, pinning `sdram_download`'s FSM in `D_IDLE`. `dl_req` never asserted, the arbiter never
  selected the download path, and **not one `CMD_WRITE` ever reached the chip** — while the HPS
  delivered all `0xE00000` bytes and the FSM's accept condition looked perfect. SDRAM was simply
  never written; every read returned power-up contents. Fix: `sdram_reset = reset & ~ioctl_download`.
- **This is invisible to simulation by construction.** A testbench drives its own reset and
  download sequencing, so it never reproduces MiSTer holding RESET across the transfer. The same
  blind spot produced two other bugs the same day: `vblank` driven as a one-clock pulse when real
  hardware holds it 38 lines, and `ioctl_index` hardcoded to 0 so an index mismatch could never
  surface. **Ask of every testbench stimulus: is this the shape the real system produces?**
- **Verify at the pins, not at the intent.** The decisive measurement was counting real commands
  on `{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE}` (`CMD_WRITE = 3'b100`), which are top-level signals.
  Delivery counters and FSM accept-condition counters both looked perfect; only the pin count
  revealed zero writes. Measure the last observable stage, not an internal signal that merely
  implies it.

## Debug instrumentation: how to not fool yourself

- **Never reset a debug counter with the reset you are investigating.** Two separate measurements
  read `0x000000` and were reported as findings before it was noticed that the counters were
  cleared by `reset` — which is asserted for the whole window being measured. Declare debug
  counters with `= 0` initialisers and **no reset at all**; Quartus powers registers to zero, so
  whatever they show is what genuinely happened since configuration.
- **A zero can mean "did not happen" OR "was never allowed to count". Design the probe so those
  differ.** Counting only dropped bytes was useless because zero drops and zero traffic look
  identical. Always pair a "bad event" counter with a "total events" counter.
- **Sample registered signals, not combinational ones, and prove the probe on a known-good
  configuration.** A tap on `cpu_data` (combinational) sampled at `cpu_ce && !as_n && !dtack_n`
  appeared to show the CPU latching byte-skewed data — a compelling and completely false finding.
  Running the *same* probe in a simulation that demonstrably boots showed the same skew, proving
  the probe mis-sampled. **Run any new probe against a known-good setup first**; if it reports a
  fault there, the probe is the fault.
- **Distinguish the address column from the data column before blaming the CPU.** A bus trace
  showing `0x00000000` was read for years as "the vector fetch address comes out wrong". It was
  the *data* read back from the correct address `0x70`, because the testbench had zeroed the
  vector table. That misreading was recorded in two docs and used to justify not trusting
  interrupts at all.
- **Measurements taken while the design fails timing are worthless.** The "~51% of ROM words
  match" figure and the original SDRAM_CLK phase sweep were both taken while the entire clk_sys
  domain failed by 8.9 ns, and both were used to rule the memory interface *out*. Re-run any
  measurement that predates a timing fix.
- **Never let the probe's step size share a factor with the period you are trying to measure.**
  The BRAM tracer's capture window skipped `window * 256` events. Windows 0, 8 and 15 (skips of
  0, 2048, 3840 — all multiples of 256) returned *byte-identical* 128-entry captures. That is
  consistent with two completely different faults: a CPU resetting every 256 reads, or a ROM read
  path aliasing every 256 words. A sampling step that is always a multiple of 256 lands on a
  period boundary of **any** stream whose period divides 256, so it cannot separate them. The step
  is now `window * 8191` — odd, so it cannot alias with a power-of-two period. When a probe gives
  the same answer at every setting, suspect the probe's step before believing the answer.
- **Truncating an address in the capture destroys the distinction between "progressing" and
  "stuck".** Packing only `addr[7:0]` into the 24-bit pixel made a genuine linear sweep through
  ROM (low bits wrapping every 256 words) look exactly like a read path dropping its high address
  bits. Capture the *full* address — if it does not fit alongside the data, use two buffers
  strobed by the same event, so entry N of each describes the same bus cycle.

## A hardware-vs-image comparison cannot detect a wrong image

The single most expensive mistake of 2026-08-23. A hardware trace of CPU ROM reads was checked
against the ROM image assembled from the `.mra` and matched **128/128**, which was reported as
"the SDRAM read path is verified sound". It was — but the same measurement was also taken as
evidence the `.mra` was right, and it could never show that: **both sides of the comparison were
built from the same assumption about byte order.** A wrong map is invisible to it.

The reset vector had to be byte-swapped in the analysis script to make it match MAME
(`SP=FFFF8000 PC=00000400`). That swap was written off as a capture artifact. It was real: the CPU
genuinely received `PC=0x00000004`, jumped to address 4, executed the **vector table as code**,
hit an illegal instruction, and looped forever fetching vector 4. The "sequential sweep from
address 0" that looked like the boot ROM checksum was actually the CPU running off the end of the
vector table.

**Use an independent oracle.** MAME's disassembly is one:

```
000404: lea $ffff7000.l,A0   -> 41F9 FFFF 7000
00040A: move A0,USP          -> 4E60
00040C: move.w #$1,D0        -> 303C 0001
000410: movec D0,CACR        -> 4E7B 0002
```

Reconstructing those exact words from the two ROM files scores 18/18 for one interleave model and
5/18 for the other, offline, in seconds, with no hardware involved. Do that **before** building.

## MiSTer caches the loaded ROM -- an .mra edit alone does nothing

Deploying a corrected `.mra` and re-launching it produced a byte-identical trace, which nearly got
the fix discarded as ineffective. Re-launching the game that is already loaded reuses the ROM.
Force a genuine reload by bouncing through the menu first:

```
POST /api/launch {"path":"/media/fat/menu.rbf"}   # then wait
POST /api/launch {"path":"/media/fat/_Arcade/.../Game.mra"}
```

## Writing a .CFG by hand silently rewrites the DIP switches

`/media/fat/config/<setname>.CFG` is the whole 128-bit status word. Writing 16 bytes with only
byte 7 set to enable a debug bit **zeroes every DIP switch**, because the `.mra`'s `<switches>`
occupy `status[55:16]`. For this core that turned **Service Mode ON** (bit 23, ids `On,Off`) and
Flip Screen on, in every capture taken that way. Either write the `<switches default>` bytes
alongside your own (`FF,FF,FD,FF,FF` -> CFG bytes 2..6 here), or delete the CFG and let MiSTer
write its own defaults.

## A malformed .mra looks exactly like a core regression

An edited comment block left a `-->` that had already closed the comment, so the new prose landed
in the document as character data -- and it contained `<- u127`. A bare `<` is illegal XML, MiSTer
rejected the file, and the result was: DIP switches gone from the OSD, ROM never loaded, core up on
an all-zero image, `SP=PC=00000000`, black screen. Every symptom pointed at the RTL. The only clue
that it was the `.mra` was the on-screen "XML parse" message, which the user saw and I did not.

`scripts/validate_mra.py` now checks well-formedness AND flags stray element text (which is how a
prematurely-closed comment shows up). Gate every deploy on it:

```bash
python scripts/validate_mra.py "releases/*.mra" && <copy to device>
```

Note MiSTer's own parser is *more lenient* than a strict one: this file had `--` inside comments
and two other comment blocks leaking text for a long time without complaint. Leniency varies by
malformation, so do not treat "it loaded before" as evidence the file is well-formed.

## Verify ROM interleave against hardware, not against "it boots"

Every `.mra` interleave map for this core that was *derived* by reasoning about byte order was
wrong; the working maincpu map was found by copying the idiom from a shipped core
(`Bucky O'Hare.mra`). "It boots" is weak evidence — a wrong map can still boot far enough to look
plausible.

`scripts/verify_rom_trace.py` closes this properly: it takes a decoded on-hardware trace of ROM
reads and the original ROM zip, brute-forces the small space of plausible interleaves, and reports
which one reproduces the observed data **exactly**. For maincpu it returned **128/128** for
"even word ← `4-u127.bin`, big-endian within part", confirming the shipped map

```xml
<interleave output="32">
    <part name="4-u127.bin" map="0021"/>
    <part name="5-u126.bin" map="2100"/>
</interleave>
```

and simultaneously proving the SDRAM read path returns byte-perfect data at those addresses. Use
the same technique on the still-unverified gfx maps (`u14.bin`, `u34.bin`, `u35.bin`, all carrying
a guessed `map="21"`) rather than reasoning about them again.

Note what it does **not** prove: the trace address is truncated, so it verifies *content*, not
*address reach*. A path that aliases high address bits still scores 100%.

## Static timing analysis (check this FIRST on any hardware-vs-simulation divergence)

- **Quartus reports "Fitter was successful" on a design that grossly fails timing. Nothing in the
  default build flow fails, warns loudly, or blocks the `.rbf`.** This project shipped an `.rbf`
  whose main clock domain had **−8.879 ns setup slack and −21,031 ns TNS** — thousands of failing
  endpoints, a worst path nearly twice the clock period — while every log line said "successful"
  and "0 errors". The only place it shows up is `output_files/<rev>.sta.summary` /
  `<rev>.sta.rpt`, which nothing forces you to open.
- **The single highest-value number is the Fmax Summary.** `emu|pll|...divclk : 48.74 MHz` against
  an 85.909091 MHz clock is instantly diagnostic and needs no path analysis to interpret. Read it
  before doing *anything* else when hardware and simulation disagree.
- **This failure mode looks exactly like a memory-corruption bug, and will send you chasing one.**
  The symptom set was: boots but reads back wrong data; ~51% of golden-ROM comparisons mismatch;
  perfectly reproducible across power cycles; completely unaffected by SDRAM_CLK phase shift; and
  100% correct in ModelSim with identical ROM data. Every one of those is *also* what a timing
  failure produces — deterministic because placement is fixed per-`.rbf`, phase-independent
  because the failing paths are internal fabric logic that the external memory clock never
  touches, and invisible in RTL simulation because simulation has no propagation delay. Days were
  spent on SDRAM pin audits, PLL phase sweeps, and controller review, all of which came back
  clean, before the timing report was opened.
- **Rule of thumb: "correct in ModelSim, wrong on hardware, reproducible, and insensitive to
  interface tuning" is a timing violation until proven otherwise.** Interface tuning (clock phase,
  drive strength, IOE registers) only moves *external* margins by a fraction of a clock period. If
  a change of that size makes no difference at all, the problem is almost certainly not at the
  interface.
- **Getting the actual failing paths requires a `quartus_sta` Tcl run** — the default `.sta.rpt`
  contains only summaries, and the "Timing Closure Recommendations" panel is HTML-only and
  therefore empty in the plain-text export. See `sta_failing_paths.tcl` in the repo root:

  ```tcl
  project_open Psikyo -revision Psikyo
  create_timing_netlist
  set_operating_conditions 7_slow_1100mv_100c   ; # NOT -slow_model / -speed 7, see below
  read_sdc
  update_timing_netlist
  report_timing -setup -npaths 50 -detail summary   -from_clock $ck -to_clock $ck -file out.rpt
  ```

  Two syntax traps cost several attempts: `create_timing_netlist -speed 7 -slow_model` is
  rejected outright, and the error message ("Values entered did not match any valid operating
  conditions") only appears if you read the lines *above* the generic Tcl failure. Use plain
  `create_timing_netlist` followed by `set_operating_conditions` with one of the exact names the
  error message lists. Also note the report is worth generating at `-detail summary` first — 50
  summary rows immediately showed every failing path shared one module, which full-path detail
  would have buried.
- **`derive_pll_clocks` + `derive_clock_uncertainty` is the entire stock MiSTer `.sdc`.** That
  constrains internal register-to-register paths (which is how the CPU failure was caught) but
  leaves every external interface — including all of SDRAM — completely unanalyzed. Both the
  Unconstrained Paths and Unconstrained I/O Ports panels will be non-empty on a stock core. This
  is normal for MiSTer and is *not* by itself evidence of a bug, but it does mean "timing passed"
  never says anything about the memory interface.

## TG68K.C (68020 CPU core)

- **TG68K.C cannot run anywhere near a typical MiSTer system clock, and it has no clock-enable
  input to protect you from that.** Measured Fmax on this project's real post-fit netlist, Cyclone
  V speed grade 7: **48.74 MHz**. Every one of the 50 worst-slack paths in the entire design was
  inside `TG68KdotC_Kernel` — the `altsyncram` register file and the `regfile_rtl_*_bypass`
  network, driven from `use_direct_data` and `exec[*]`, needing ~19.6 ns. Nothing else in the
  design (video pipeline, SDRAM controller, sound) failed timing at all. Budget for the CPU to be
  the Fmax-limiting block in any design that includes it.
- **`TG68K.vhd` is an async-68000-BUS ADAPTER, not the CPU. Do not rate-limit it — bypass it.**
  This is the single most expensive mistake made on this project. `TG68K.vhd` wraps the real core
  (`TG68KdotC_Kernel`) in a 68000 bus-protocol emulator that assumes `CLK` **is** the CPU clock:
  it has `falling_edge` registers (`as_e`, `rw_e`, `uds_e`, `lds_e`, `clkena_e`, `data_akt_e`,
  `cpuIPL`, `waitm`, `E`) precisely because it reproduces real 68000 bus phases. Slowing it down
  means fighting its design.
- **The kernel is what you clock-enable, and it is designed for exactly that.**
  `TG68KdotC_Kernel` is **entirely rising-edge** (verified: zero `falling_edge` occurrences) and
  exposes `clkena_in` for this purpose. Established cores instantiate the kernel DIRECTLY and own
  the bus interface themselves. `mist-devel/plus_too`'s `tg68k.v` is the canonical example:

  ```verilog
  wire tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01);
  ```

  Its own state machine handles DTACK and stalls the CPU purely by gating `clkena_in`; the bus
  interface is `busstate`/`addr_out`/`data_in`/`nUDS`/`nLDS`/`nWr` (`busstate == 2'b01` means "no
  memory access", so the CPU free-runs). There is no AS/DTACK adapter and nothing inside the core
  is modified.
- **What NOT to do (all of it was tried here, and all of it failed).** Adding `ext_clkena` to
  `TG68K.vhd` and gating every clocked process appears to work — `tb_maincpu` passed both cases
  and the real-ROM sim booted — but it drags in a chain of consequences: the two clock edges need
  two separate enables (a rising-edge register samples the enable held during the PRECEDING
  period, so one shared enable runs each emulated CPU cycle's halves in the wrong order), and then
  the timing report needs a `set_multicycle_path` to accept the result, which is where it becomes
  genuinely dangerous — see the half-cycle warning below. Four layers of scaffolding on a
  battle-tested core, and it still did not boot on hardware.
- **NEVER let a multicycle constraint touch a posedge->negedge path.** A constraint matching
  `{*TG68K:*|*}` sweeps the wrapper's falling-edge registers into the collection and grants a
  HALF-cycle path (~5.8 ns at 85.909091 MHz) two or four FULL cycles — up to ~46 ns. The Fitter
  will happily route it that slowly, the timing report stays clean, and the design fails only on
  silicon. Two of those registers are `waitm` (the DTACK sample) and `data_akt_e` (which gates the
  DATA tri-state), so relaxing them corrupts bus handshaking directly. If a multicycle is needed
  at all, scope it to a block you have verified is single-edge, and explicitly
  `remove_from_collection` any falling-edge registers from BOTH ends.
- **Derive an enable ratio exactly rather than rounding.** clk_sys here is the real 14.318181…MHz
  screen XTAL x 6 = 945/11 MHz and the 68EC020 wants 176/11 MHz, so the enable rate is exactly
  176/945 and a Bresenham accumulator hits it with zero error. The tempting integer divides are
  both meaningfully wrong: /5 is 7.4% fast, /6 is 10.5% slow. (Alternatively drop clk_sys to
  42.954545 MHz = 14.318181 x 3, which keeps the pixel divide exact at 6:1 and is under TG68K's
  measured Fmax outright.)
- **Uninitialized signals in arithmetic crash ModelSim.** `TG68K_ALU.vhd`/`TG68KdotC_Kernel.vhd`
  have many `std_logic`/`std_logic_vector` signals with no default initializer; ModelSim's `'X'`
  propagates through arithmetic from time 0 and can cascade into multi-GB allocation failures /
  SIGSEGV once a real program (not a 4-instruction spike) exercises enough logic. This is a known
  upstream issue (github.com/TobiFlex/TG68K.C/issues/21). Fix: explicit zero initializers on
  every affected signal (123 total) — simulation-fidelity only, doesn't change real behavior.
  Same class of fix as `sdram.sv`'s uninitialized `state`/`ack0..2` registers below.
- **RESET/HALT are genuine open-collector nets, and Quartus does NOT resolve them like ModelSim
  does.** TG68K.vhd drives `RESET <= '0' WHEN nResetOut='0' ELSE 'Z'` (and same for `HALT`) itself
  — needed because the core can self-assert reset via its own RESET instruction — while the
  wrapping SystemVerilog also needs to drive these lines, making them a real multi-driver
  open-collector bus. SystemVerilog `tri1` models this correctly in simulation (resolves to weak-1
  when undriven, proper wired-AND). **Confirmed via real Quartus synthesis + real hardware bring-up:
  Quartus 17.0 converts this into a plain selector/MUX** (`Warning (13048): Converted tri-state
  node "..." into a selector`), not genuine wired-AND resolution — and that selector's behavior for
  the idle/both-released-to-Z steady state is broken on real silicon: the resolved value gets stuck
  low (permanent reset), even though ModelSim simulates the same RTL correctly. This is a real
  synthesis-tool divergence, not a simulation mismodel — confirmed by a live hardware debug tap
  (VGA-color-coded builds, see "Real hardware bring-up" below) showing the kernel reset signal
  stuck asserted on actual DE10-nano hardware while simulation showed it working.
  - **Fix pattern that works**: do NOT make either side of the shared tri-state net non-tri-state
    (see "Quartus multi-driver conflicts" below — this creates a hard synthesis error, not just an
    ambiguity). Instead add a genuinely separate, single-driver signal and OR it into whichever
    downstream computation actually needs the correct value: e.g. a new `ext_force_run` input port
    on TG68K.vhd, with `cpu1reset <= (RESET OR HALT) OR ext_force_run;`. `1 OR anything = 1` lets a
    clean external signal force the correct steady-state result without ever creating a second
    driver on the original (still-tri-state, still nominally fragile) net.
  - **Check every consumer of the broken signal, not just the first one found.** The wrapper's own
    bus-cycle state machine (`S_state`, `as_s`/`rw_s`/`uds_s`/`lds_s`, and the falling-edge
    `as_e`/`clkena_e`/etc. pair) used the same raw `RESET` directly as its async reset condition —
    fixing only the kernel's `nReset` input left the CPU out of reset but bus-cycle generation
    still stuck, producing zero bus cycles. Needed a second `effective_reset` signal (same
    OR-with-`ext_force_run` pattern) substituted into that state machine's sensitivity list and both
    async-reset conditions. A useful debugging signature for "fixed one consumer, missed another":
    the CPU stops asserting reset but still never generates any bus activity.
- **SystemVerilog hierarchical references into VHDL internals work in ModelSim but do NOT
  elaborate for Quartus synthesis, at any depth.** Tried both a one-hop (`u_cpu.cpu1reset`) and a
  two-hop (`u_cpu.cpu1.Reset`) reference for debug taps — both gave
  `Error (10207): can't resolve reference to object`. The only working alternative: add a genuine
  new output port directly to the vendored VHDL entity, exposing the internal signal as a real
  port. Unconnected new ports at other instantiation sites are legal — no need to touch every
  caller.
- **68020-mode instruction coverage was real, not assumed** — Phase 0 spike specifically exercised
  68020-only opcodes (MULU.L, DIVU.L, scaled-index addressing, BFEXTU) before committing further,
  and two apparent "core bugs" during that spike turned out to be testbench mistakes (see
  `rtl/cpu/tg68k/PROVENANCE.md`).

## Quartus synthesis gotchas (not visible in ModelSim)

- **Non-blocking assignments to block-local (`automatic`) variables are rejected**, even with the
  `static` keyword, in a pattern that compiles fine under ModelSim —
  `Error (10959): illegal assignment - automatic variables can't have non-blocking assignments`.
  Fix: move the affected variables (`sdram.sv`'s `rfs_cnt`/`rfs`/`rfs2`/`init_old`) to module-level
  declarations, matching every other register in the file. Pure declaration-scope change, no
  behavior change — always re-run the full ModelSim regression after this class of fix to confirm.
- **Negative PLL phase shifts aren't legal for every PLL configuration.** `quartus_fit` rejected a
  `-3000ps` phase shift outright; only `0ps` and positive values in fixed steps (~132.275ps here)
  are legal. Fix: convert to the equivalent positive phase (`period - abs(shift)`, rounded to the
  nearest legal step Quartus itself reports in the error message).
- **A non-power-of-2 modulo synthesizes as a slow generic iterative divider and can dominate
  timing closure.** `sprite_index <= sram_data % 16'd768;` produced Quartus's single worst timing
  path in the whole design (`Mod0|auto_generated|divider`). Fix: replace with an explicit
  N-stage conditional-subtraction chain (subtract decreasing power-of-2 multiples of the modulus
  when they fit) — standard technique for modulo-by-compile-time-constant, same one-cycle
  combinational timing, no interface change. Cut this design's worst-case setup slack by 81%.
  Worth checking `report_timing`'s worst path directly rather than guessing which module is at
  fault — the divider was buried inside `sprite_display_list_walker.sv`, not obviously the
  suspect from a design read-through alone.
- **Quartus multi-driver conflicts on a shared tri-state net are a hard, unsynthesizable error,
  not just an ambiguity Quartus can resolve.** Making *either* side of an existing open-collector
  net (e.g. TG68K's RESET/HALT) non-tri-state while the other side still drives it produces
  `Error (13076): "..." has multiple drivers due to the non-tri-state driver "..."` — and this can
  surface at a much deeper internal signal than the one you touched (e.g. fixing `cpu1reset`
  surfaced a conflict on `TG68KdotC_Kernel:cpu1|syncReset[3]`, a signal several levels further into
  the vendored core). See the TG68K RESET/HALT fix pattern above for the working alternative
  (a separate single-driver signal OR'd in, never a second driver on the original net).
- **`quartus_map` (Analysis & Synthesis only) is a fast pre-check** (~2-3 min vs. ~5-6 min for a
  full `quartus_sh --flow compile`) for whether an RTL change even elaborates/synthesizes, worth
  running before committing to a full place-and-route round trip. Quartus auto-parallelizes across
  available CPU cores with no explicit configuration needed; ModelSim/vsim in this edition is
  single-threaded, no equivalent lever there.

## SDRAM / DDRAM

- **DDRAM (`DDRAM_*`) is documented as unsuitable for hard-real-time per-tile fetch budgets** —
  MiSTer's own docs describe it as for "non-critical time purposes" with latency that "can be way
  longer" than typical (~20 cycles), an unbounded worst case, not just a high average. Confirmed
  directly: `tb_video_pipeline_ddram.sv` measured ~26 combined cycles against a 16-cycle-per-tile
  budget under realistic two-consumer contention. `SDRAM_*` (Sorgelig's `sdram.sv`, vendored into
  many MiSTer-devel arcade cores) gives 3 independent ports at fixed, bounded ~6-7 cycles — the
  right backend for this traffic class. If a design starts on DDRAM for convenience, budget time to
  pivot rather than trying to patch throughput after the fact.
- **A reference SDRAM controller with no burst support needs real command-sequencing verification
  when extended to burst-N, not just a black-box latency stub.** Adding burst-4 to `sdram.sv`
  needed a chip model that actually decodes `nRAS`/`nCAS`/`nWE`/`SDRAM_A` — that's what caught: (1)
  the row/column address split needing to swap (a hardware burst auto-increments the *column*, so
  4 consecutive word addresses must land at 4 consecutive columns of the *same* row — the
  non-bursting upstream reference had this split arbitrarily the other way, which only matters once
  bursting is added), (2) the chip model silently ignoring the `DQML`/`DQMH` byte-lane write mask,
  (3) an off-by-one in burst-read CAS timing (a dropped `+1` registration-delay margin).
- **A shared read-data register across multiple logical "ports" is a real hazard even when the
  address/data buses are otherwise independent.** `sdram.sv`'s `dout0`/`dout1`/`dout2` are
  literally the same underlying register — a consumer must sample on its *own* valid/ack cycle,
  never later, or it can read another port's in-flight data. A contention testbench that samples
  outside each port's own ack-triggered branch will show 100% failures that look like an RTL bug
  but are actually a testbench sampling-discipline bug — worth checking the test's sampling point
  before concluding the RTL is broken.
- **A `rom_pending`/similar request-tracking flag must clear on the actual bus cycle ending, not
  on the ROM interface's one-cycle `valid` pulse**, if the CPU can hold the bus cycle open longer
  than the fetch itself (real 68k bus cycles hold `as_n` low for several cycles after DTACK
  releases). Clearing early lets a spurious second request fire for data already latched — harmless
  in isolation, but under real multi-client contention another client can win that spurious slot's
  arbitration and overwrite a shared read-data register before the original cycle finishes,
  corrupting what the CPU samples. Symptom looked like SDRAM corruption; root cause was in the CPU
  wrapper's own request lifecycle, not the SDRAM stack — worth checking every request-tracking flag
  against the actual bus protocol's cycle length, not just its own "data arrived" signal.
- **Nothing in the SDRAM read stack latches read data — the entire path from `sdram.sv`'s `dout`
  to the CPU's data bus is combinational, and valid is a one-cycle pulse.** `sdram.sv` assigns
  `dout0`/`dout1`/`dout2` from one shared `dout` register (upstream does this too);
  `sdram_arbiter5` assigns `c*_data = phy_rdata` and `c*_valid` combinationally; and
  `sdram_narrow_bridge` selects its word with `sel_word = g_data[16*word_sel +: 16]` with no
  register anywhere. The consumer is therefore *required* to capture on the valid pulse.
  `maincpu.sv` originally got away with reading it combinationally only because TG68K.C re-captured
  `DATA` on every clock edge while parked in its wait state, so the one-cycle window always
  landed — an alignment that holds by one cycle and breaks the moment the CPU stops stepping every
  cycle. **Any change to how often a consumer samples the bus (a clock enable, a different clock
  domain, an extra pipeline stage) requires latching both the data and the ready/DTACK level
  first.** Fixed here with `rom_data_l`/`rom_ready` in `maincpu.sv`, held until the CPU drops
  `as_n`; as a bonus this also closes the shared-`dout` overwrite exposure described in the
  `rom_pending` note above, because once captured the word can no longer be clobbered.
- **DTACK/ready must be a held level, never a pulse, for any CPU core driven by a clock enable.**
  A core stepping at 16 MHz inside an 85.909091 MHz fabric looks at DTACK roughly once every 5.4
  cycles; a one-cycle assertion is missed on nearly every access and the bus cycle hangs forever.
  Check every ready/ack signal feeding a gated core against this before enabling the gate.
- **A request/ack round-robin arbiter needs every request port on a hold-until-acknowledged
  contract**, not a one-shot pulse — a one-shot request arriving while the arbiter is servicing
  another client is silently lost. Applies uniformly across `ddram_arbiter`/`sdram_arbiter5` and
  the HPS download path (`ioctl_wr` is a genuine one-shot from hps_io and needs a wrapper, e.g.
  `sdram_download.sv`, translating it into hold-until-ack via `ioctl_wait` backpressure).
- **Byte-order/endianness bugs live at the seam between two independently-correct modules, not
  inside either one.** `sdram.sv`'s burst capture packs bytes in plain ascending-address order;
  gfx-ROM consumers assumed MAME's MSB-first packed format; a maincpu program ROM needed
  big-endian while `sdram_narrow_bridge.sv`'s generic word path was little-endian (correct for
  other, genuinely little-endian regions like spritelut). Every prior test that used uniform/all-
  zero ROM content couldn't have caught this — it's invariant under byte order. Fix each seam with
  a small dedicated adapter (`gfxrom_byte_reorder.sv`, a maincpu-specific byte swap) rather than
  changing the shared module's convention out from under its other, already-correct consumers.
  General lesson: when a wiring bug surfaces, prefer a synthetic/uniform-data smoke test first to
  catch crashes cheaply, but know that non-uniform, byte-order-sensitive content is required to
  actually catch this class of bug — budget a real-content integration test before trusting a
  uniform-data one.
- **Two logically separate reset domains matter when one subsystem must stay live during another's
  reset.** Wiring a single shared `reset` into both the core (CPU/video) and the SDRAM backend
  meant that sequencing a "hold reset through the whole ROM download" test — the natural way to
  write such a test — silently discarded every downloaded byte, because the SDRAM backend's own
  req/valid wrappers were held in reset for the exact span they most need to be live. Fix:
  `core_reset = reset | ioctl_download` gates only the core; the SDRAM backend keeps the plain
  `reset`. Symptom was a state machine stuck at its idle state despite the write-strobe input
  pulsing correctly — worth checking reset domain overlap whenever a downstream FSM looks like
  it's simply not receiving its trigger despite the trigger firing.
- **Contention/throughput problems from a shared single-pipeline resource (one physical SDRAM
  chip, multiple logical consumers with correlated timing) may need a deeper buffer on the consumer
  side, not just better arbitration.** Two tilemap layers with identical scanline timing request in
  near-lockstep; a 2-entry ping-pong prefetch buffer only absorbs one simultaneous loss, so ~1-in-5
  tiles stalled when both layers' requests collided. Widening to a parameterized N-entry ring
  buffer (interface unchanged) absorbed the stalls. This is a real fix for the tested contention
  pattern, not a formal guarantee against every pattern — a genuinely independent fetch-ahead
  domain or a pipelined controller remains the architecturally complete fix if a deeper buffer ever
  proves insufficient.

## T80 / Z80 sound CPU wrapper (req/valid ROM timing)

- **Deriving correct `WAIT_n` timing for a synchronous req/valid ROM against a real CPU core needs
  the CPU's *internal* T-state/M-cycle behavior, not just external bus-signal inference.** A first
  attempt based on top-level signal tracing alone hit a real, reproducible bug (a multi-byte opcode
  whose own read M-cycle follows two operand-fetch M-cycles corrupted the destination register,
  with no visible access to the target address anywhere in the external trace) and had to be
  reverted. The fix required reading `T80.vhd`/`T80se.vhd`'s actual RTL: `TState` freezes at a
  known value for as long as `WAIT_n` reads 0 (resampled every cycle, no separate edge logic), data
  is captured on the exact edge that condition first goes true, and `RD_n`/`MREQ_n` are registered
  outputs defaulting high every cycle — meaning there's always a real one-cycle gap between M-cycles
  even within one multi-byte instruction, a fact a "same-cycle edge-detector" design can't safely
  assume without the internal read. With that understanding, a level-tracked `rom_pending` flag
  gated by a glitch-free combinational `is_rom_read` level (not an edge detector) is structurally
  unable to miss a transition.
- **Verify against internal CPU tracing, not just external pass/fail, when the first design attempt
  already failed once for a subtle timing reason** — re-running the same failing scenario with
  hierarchical access to the CPU core's own `MCycle`/`TState` signals (not reconstructed from
  external bus signals) is what actually confirmed the fix, not just "the test passes now."

## Testbench pitfalls (recurring pattern, multiple modules)

- **`while (signal) @(posedge clk);` races against an `always_ff` updating that same signal on the
  same edge.** Checking a busy/wait signal in the same active-region delta cycle as the RTL's own
  non-blocking update can read the stale value and either deadlock (waiting forever on a signal
  that already cleared) or return too early (missing a transaction that hasn't started yet).
  Recurred independently in at least three testbenches (`ddram_phy_tb`, `sdram_download`
  integration, `psikyo_sdram_top` integration) before the pattern was recognized as systemic.
  Fix: `do @(posedge clk); while (signal);` — guarantees at least one full edge (and NBA settle)
  before the first check. Worth using this form by default for any wait-loop on RTL-driven status
  signals, not just after hitting the bug once.
- **A sticky "error latched" output can produce an unavoidable false alarm at cold start**, and once
  latched is permanently indistinguishable from a real later failure. `fetch_overrun` in
  `tilemap_line_engine` triggers unavoidably on the very first active line after reset (no prior
  hblank to prefetch into) — no amount of reset-timing adjustment changes this, because the
  triggering condition is genuinely true at that moment. If a sticky DUT output can have an expected
  benign trigger, don't check the sticky output directly in a test that needs to detect *later*
  problems — independently replicate the DUT's own trigger condition via a non-sticky per-cycle
  check instead.
- **Drive stimulus with its REAL waveform shape, not a convenient pulse — a level driven as a
  one-clock pulse hides whole classes of bug.** `tb_maincpu.sv` pulsed `vblank` high for exactly
  one clock. Real hardware holds it for the entire 38-line vertical blank — ~2.4 ms, ~205,000
  clk_sys cycles. That single difference hid a genuine `maincpu.sv` bug for the whole project:
  the IRQ logic was `if (vblank) set; else if (iack) clear;`, giving *set* priority, so an
  acknowledge arriving while vblank was still high (which is what always happens on hardware,
  since the CPU responds in microseconds) was silently discarded. `irq_pending` then never
  cleared, `ipl` stayed at level 4, and the CPU re-entered the ISR after every `RTE` — the main
  program could never advance past its first vblank. With a one-clock pulse the acknowledge always
  landed after vblank had fallen, so the test passed every time.
- **A held interrupt line must let the acknowledge win.** Match MAME's `irq4_line_hold` exactly:
  assert on the **rising edge** of the source, hold until acknowledged, and give the acknowledge
  priority in the priority chain. Ask of every level-sensitive input: *is this signal still
  asserted when the consumer responds?* If yes, set-vs-clear priority is a real design decision,
  not a formality.
- **Write preloaded vectors/tables AFTER `$readmemh`, never before — an assembled image silently
  overwrites them with its own zero-filled gaps.** `tb_maincpu.sv` installed the level-4
  autovector entry at `rom[0x38]`/`rom[0x39]` (byte `0x70`) and then `$readmemh`'d a program image
  contiguous from byte `0x8` past an ISR at `org $100`. That image spans byte `0x70`, so its empty
  `0x70`-`0xFF` region zeroed the entry that had just been written. The CPU then took the
  interrupt correctly, fetched the correct vector address, read zero, jumped to `0x00000000`,
  executed zeroes until it hit an illegal instruction, and vanished into vector 4.
- **This cost a genuinely expensive misdiagnosis: it was recorded for weeks as a TG68K.C exception
  microcode bug**, in both `PROVENANCE.md` and `ROADMAP.md`, and used as the standing reason
  interrupt-driven integration "couldn't be trusted yet". The trigger for the wrong conclusion was
  misreading a bus trace — `0x00000000` was the *data* read back from the vector table, not the
  address the CPU fetched from, which was correctly `0x70` all along. **When a trace shows an
  exception jumping somewhere implausible, confirm which column is address and which is data
  before blaming the CPU**, and suspect a zeroed vector table long before exception microcode.
- **`$readmemh` failing silently turns a whole testbench into a false regression report.** When
  `sim/maincpu_tb/tb_maincpu.sv` was run with `vsim` launched from its own directory rather than
  the repo root, its `$readmemh("sim/maincpu_tb/test_maincpu.hex", ...)` found nothing, the ROM
  stayed all-zeroes, and every single check failed — reading exactly like a catastrophic RTL
  regression ("bus wedged", all regions `0000`) and prompting a wrong diagnosis (scaling
  timeouts) before the one-line `** Warning: (vsim-7) Failed to open readmem file` was noticed.
  ModelSim reports this as a *warning*, not an error, and it scrolls past in the elaboration
  noise. **When a testbench fails wholesale rather than in one specific check, grep the log for
  `readmem` before touching any RTL.**
- **`$readmemh` paths are relative to the simulator's working directory, not the testbench file's
  location** — recurred across `tb_maincpu.sv` (needs running from repo root), and
  `tb_psikyo_core.sv`/`tb_psikyo_top.sv` (needs running from their own subdirectory, plus
  `vmap work ../../work` to share the compiled library). A "first run fails with 0 matches / all-X
  data" on a new testbench is worth checking against CWD before assuming an RTL bug.
- **When a regression appears to fail after a change, check whether it fails on a clean stash of
  the change too** before debugging the change itself — a missing/stale test-fixture file (not a
  regression at all) can look identical to a real regression. `git stash` + re-run is a cheap way
  to rule this out before spending time on the wrong hypothesis.
- **Smoke tests (elaborate + run N cycles, check for crash/X-propagation only) are worth writing
  before a full functional test** on any new top-level integration — cheap, and catches basic
  wiring mistakes (e.g. a port-width mismatch) before investing in the harder job of writing a real
  functional check.

## Real hardware bring-up (MiSTer / DE10-nano)

- **The `.rbf` must live in the top-level cores directory** (`/media/fat/_Arcade/cores/`), not a
  subdirectory relative to the `.mra` files. `.mra` files reference the `.rbf` via a bare
  `<rbf>Arcade-Psikyo</rbf>` tag (no date suffix) and MiSTer resolves it by prefix-matching
  filenames in that one directory. A misplaced `.rbf` produces a silent "flash and return to menu"
  with no error, before ROM loading even begins — easy to misdiagnose as a core/ROM-loading bug
  when it's purely a file-placement issue.
- **MiSTer Remote API** (wizzomafizzo/mrext, port 8182) is a real, documented HTTP API — fetched the
  actual Go source (`cmd/remote/main.go`, `cmd/remote/games/launchers.go`) rather than guessing.
  `POST /api/launch {"path": "<abs path>"}` writes `load_core <path>\n` to MiSTer's own
  command-interface device file, the same low-level primitive the menu itself uses — no caching
  layer to worry about. `POST /api/screenshots` triggers a screenshot save but its JSON response is
  unreliable/effectively empty regardless of success — the real signal is a new file appearing
  under `/media/fat/screenshots/<core-shortname>/`, often with several-seconds-plus lag; poll for
  the new file rather than trusting the response. `GET /api/games/playing` reports the currently
  loaded core/game. The Remote API also supports input injection for future automated gameplay
  testing (not yet used here) — worth revisiting once boot-level bring-up is stable.
- **MSYS/Git-Bash silently mangles absolute-POSIX-looking command-line arguments** (e.g.
  `/media/fat/...`) into Windows paths (e.g. `C:/Program Files/Git/media/fat/...`) when passed to a
  non-MSYS program. Caused a real, silent bug (an automated deploy script launched a garbage,
  mangled path with no error) before being diagnosed. Fix: prefix invocations with
  `MSYS_NO_PATHCONV=1`.
- **A fully-automated deploy-then-launch script needs an explicit settle gap that manual multi-step
  testing gets "for free."** Doing `deploy_rbf()` immediately followed by `launch_mra()` with zero
  gap hit a real race (the new `.rbf` wasn't reliably visible/flushed yet) that never showed up
  when the same two steps were run manually as separate tool calls (which naturally had multi-second
  gaps between them). Fix: `sync` at the end of deploy, plus an explicit short sleep before launch
  in the automated path.
- **PuTTY's `plink.exe`/`pscp.exe` are the practical way to do non-interactive SSH/SCP with password
  auth on Windows** (OpenSSH doesn't support clean non-interactive password auth, and `sshpass`
  usually isn't installed): `echo y | plink.exe -ssh -pw <password> user@host "command"` — the
  `echo y` auto-accepts an unseen host-key prompt.
- **VGA-color-override debug builds are an effective bisection technique for real-hardware
  yes/no questions when there's no logic analyzer or JTAG access yet.** Overriding `VGA_R/G/B`
  directly (bypassing the normal compositor path) with a solid color gated by an internal signal of
  interest turns "is this internal condition true on real hardware" into a single, unambiguous
  screenshot — used successfully for: confirming the video datapath itself works at all (solid
  red), a 3-way readout of CPU ROM-fetch activity via sticky latches (red/blue/green), and a 4-color
  readout adding live kernel-reset state (cyan). Always fully remove this instrumentation (all
  `dbg_*` ports and their wiring) once the real bug is found and fixed — it should never persist
  into a "real" build.
- **MiSTer's `/dev/fb0` framebuffer is the ARM-side OSD/menu overlay surface, not the FPGA's
  composited game video output.** Don't use it as evidence about what the core's own video pipeline
  is doing — use the screenshot API instead, which does capture real scaler-composited output.
- **When a race/latency bug is suspected in an automated tool, verify against the exact previously-
  working manual sequence before assuming the deployed binary is stale or wrong** — comparing a
  failing automated run against a known-good manual run isolated the bug to the automation's own
  timing rather than the build, in this project's case.
- **The DE10-nano SDRAM pinout has an authoritative reference already inside the repo — don't go
  to the web for it.** `Psikyo.qsf` does `source sys/sys.tcl`, and `sys/sys.tcl` (lines ~51–98)
  *is* the vendor MiSTer template's own SDRAM pin block. Cross-check against a third artifact,
  `output_files/<rev>.pin`, which records where every signal actually landed post-fit. All 38
  SDRAM signals were verified identical across all three. Note `Psikyo.qsf` also *restates* every
  one of those location assignments after the `source` line (the Quartus IDE re-saved the project
  despite the file's own warning not to open it there) — identical values today, so harmless, but
  a real maintenance hazard: a future `sys.tcl` update would be silently overridden.
- **Fitter warning 176250 "Ignoring invalid fast I/O register assignments" is almost always
  benign, and the Ignored Assignments panel names exactly which one.** Here it was `HDMI_TX_CLK`,
  which is driven by an `altddio_out` clock-forwarding primitive — the DDIO already occupies the
  IOE output register, so there is no core register left to migrate and the assignment is
  correctly dropped. The companion 176251 covers `SDRAM_nCS`/`SDRAM_CKE` (tied to constants) and
  `SDRAM_CLK` (a raw PLL output) matching the `-to SDRAM_*` wildcard — also nothing to pack. Do
  not read either warning as evidence about the SDRAM *data* path: confirm by counting the
  register-packing entries, which showed 16/16 fast input, 16/16 fast output and 16/16 output-
  enable registers packed on `SDRAM_DQ`.
- **`Psikyo.srf` (the message-suppression file) is inherited from another core and suppresses
  messages worth seeing** — notably 15705 ("Ignored locations or region assignments") which could
  in principle hide a dropped pin assignment. It still contains entries referencing `de10_top.v`,
  a file that does not exist in this repo. Verify against `output_files/<rev>.pin` rather than
  trusting that no suppressed message mattered.
- **The SDRAM_CLK phase shift is a legitimate parameter but a poor first suspect.** `-3 ns` is the
  standard MiSTer/DE10-nano convention; this project expresses it as the equivalent positive
  `"8598 ps"` because this `altera_pll` configuration rejects negative values outright (a real
  `quartus_fit` error, not a style preference) and quantizes to ~132.275 ps steps. Sweeping it to
  `0 ps` produced byte-identical results to `8598 ps` — which was the clue that the fault was not
  at the memory interface at all. Revert diagnostic PLL probe values immediately once measured;
  leaving `phase_shift1` at a scratch value is an easy trap for a later build.

## Tooling / workflow (Quartus, ModelSim, and the shell around them)

- **Working directory does not reliably persist into backgrounded shell commands.** A `cd` done in
  a previous call, or inside a `&&` chain, may or may not still apply. Every Quartus/ModelSim
  invocation must either be launched as `cd <project dir> && <tool>` in one command line, or be
  made cwd-independent. The most robust fix for Tcl-driven tools is to put the `cd` *inside the
  Tcl script* (`cd D:/Mister-Psikyo` as the first line of `sta_failing_paths.tcl`) so the launch
  command's cwd stops mattering at all. Symptom when this bites: `Error (23018): Tcl Script File
  ... not found`, or `Error (12007): Top-level design entity "Psikyo" is undefined`.
- **`quartus_sta`/`quartus_map`/`quartus_sh` are not on `PATH`** in this environment; invoke by
  full path (`/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sta.exe`). Note there are two Quartus
  installs on this machine — `intelFPGA_lite/17.0` and `altera_lite/24.1std`. The project was
  built with 17.0.2; use it, or the post-fit database will not match.
- **Never leave duplicate tool instances running against the same project.** Overlapping
  `quartus_map` runs corrupt the shared log; two `vsim` instances launched against the same
  testbench both write the same output file and killing one can take the other down with it
  (`Fatal: vish lost connection to vsim process` / `Kernel lost connection to front end`). Check
  `tasklist | grep -i <tool>` before every launch.
- **Killed ModelSim runs leave orphaned `vsimk.exe` kernels that keep spinning at 100% CPU
  indefinitely — across sessions, across days.** Six of them were found still running from the
  previous day, having burned ~90,000 CPU-seconds between them (one alone had 32,367 s / 9 hours).
  They are easy to dismiss because their working set drops to ~42–50 MB, versus ~180 MB for an
  active kernel — size is *not* a liveness signal here, and neither is `tasklist`, which shows no
  CPU column. **Always check CPU time, not memory:**

  ```powershell
  Get-Process vsim,vsimk | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime
  ```

  `taskkill //PID <n> //F` fails against these ("could not be terminated"); PowerShell
  `Stop-Process -Force` succeeds. Left alone they starve every subsequent simulation of CPU, which
  then looks like the *new* run being pathologically slow — a false lead that directly wastes the
  monitoring discipline these runs are supposed to have. Sweep for them at the start of any
  session that runs simulations.
- **Never run Quartus wrapped in `nohup ... &`.** It detaches, the tool call reports "completed"
  immediately, and the real process runs untracked. Launch the tool directly as the command and
  let the harness background it.
- **Never switch git branches while a Quartus process is reading the source tree** — it silently
  kills the run, leaving a truncated log that looks like a tool crash.
- **The ModelSim `work` library lives at the repo root** (`/d/Mister-Psikyo/work`), mapped by each
  testbench directory's own `modelsim.ini` via `work = ../../work`. Run `vsim` from the testbench
  directory so that `modelsim.ini` is picked up. To re-test after an RTL change, recompile only
  the changed files into the existing library (`vcom <file>.vhd`, `vlog -sv <file>.sv`) rather
  than rebuilding everything.
