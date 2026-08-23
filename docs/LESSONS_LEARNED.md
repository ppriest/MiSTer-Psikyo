# Lessons Learned

Cross-cutting technical lessons from building this core — patterns, gotchas, and tool
behaviors likely to recur. Organized by topic, not chronology. For the blow-by-blow history of
*when* each of these was found, see git log / commit messages; per-component vendoring detail
lives in each module's own `PROVENANCE.md` (`rtl/cpu/tg68k/`, `rtl/memory/sdram/`,
`rtl/sound/jt10/`, `rtl/sound/jt49/`).

## TG68K.C (68020 CPU core)

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
