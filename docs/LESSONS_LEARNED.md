# Lessons Learned

Reusable rules from building this core, for whoever builds the next MiSTer arcade core. Each entry
states the rule, the mechanism that made the wrong assumption plausible, and the evidence that
settled it. Not a status file: current state is in `docs/ROADMAP.md`, design detail in
`docs/phase*.md`, vendoring detail in each module's `PROVENANCE.md`.

## Diagnosis discipline

### Suspect your own integration before any vendored module

TG68K.C, T80, Sorgelig's `sdram.sv`, MRA/ROM loading, `hps_io` and `sys_top` ship in many working
cores. One investigation suspected, in order: SDRAM pin assignments (38/38 correct), SDRAM_CLK phase
(byte-identical output a quarter period apart), the burst-4 controller, the `.mra` interleave
(correct; "fixed" wrongly, then reverted) and TG68K's exception microcode (a testbench bug). The
cause was integration glue this project wrote. Rank hypotheses by how many shipping cores would have
to be broken for them to be true.

### Treat a conspicuous omission in a vendored module as deliberate

Upstream `sdram.v` has no reset port at all -- it is driven purely by `init` -- precisely so a core
reset cannot disturb memory. This project's wrapper added one, which created the ROM-download
hazard below. Read the upstream intent before overriding it.

### Read both halves of a mechanism before changing it

Sprite depth ordering was inverted on the strength of MAME's draw loop alone
(`while (sprite_ptr != m_spritelist.get()) { sprite_ptr--; ... }` reads as "draws backward, so entry
0 lands on top"). Never checked: `sprite_frame_buffer`'s `write_en` is unconditional so later writes
win, and the *append* side of `get_sprites()`, which decides the net order. Hardware inverted; the
change was reverted. Half a mechanism is enough to build a confident wrong change.

### Read the framework's source instead of inferring its behaviour

DIP switches were assumed to arrive through the status word, and two fixes were built on that
assumption -- a `.CFG` generator and a `base="16"` attribute on `<switches>` -- both invented. One
read of `Main_MiSTer`'s `mra_loader.cpp` showed DIPs arrive as an ioctl download with index 254,
saved to `config/dips/<mra name>`, and that `<switches>` has no `base` attribute because
`hexstr_to_char()` is always hex.

### Copy a driver's register expression including its operators

`psikyo_v.cpp` enables a layer with `m_tilemap[layer]->enable(~layer_ctrl[layer] & 1);`.
`vreg_decode.sv` had `assign layer0_enable = l0_ctrl[0]` -- right bit, wrong sense -- so both layers
were off for every value the game writes, the compositor fell through to backdrop, only sprites
appeared, and the search went into fetch paths and VRAM contents. Where MAME writes `~x & 1`,
`!(x & 1)` or `x & 8 ? 0 : 15`, carry the sense across and comment it: a polarity error passes review
because the bit index looks correct.

### Make the hardware report its own state rather than re-reading the RTL

That polarity bug was found by extending the debug overlay to dump the video-register RAM. One
screenshot showed the control word the CPU had written (`0x00D0`, bit 0 clear) beside the core's
decoded `layer_enable` of 0. Dump the register, not the intent.

### Prefer a hypothesis that predicts the number exactly

Tilemaps rendered correct content across exactly 28 columns of every scanline, backdrop for the
other 292, with `fetch_overrun` set. Chased as memory bandwidth (contention, arbiter priority,
prefetch depth). Cause: `tilemap_line_engine` had no `ce_pix` port, so its display side advanced one
pixel per `clk` (85.909 MHz) instead of per pixel clock (85.909/12 = 7.159 MHz).

```
21 tiles x 16 px = 336 pixels, one per clk = 336 clk cycles
336 / 12 clk-per-pixel                     = 28 displayed pixels
```

28 of 320 is not "about an eighth", it is 336/12, and that division identifies the cause. Contention
would give a ragged, load-dependent boundary, not the same column every line. Corollary: any module
feeding the compositor directly must consume at `ce_pix`; only a module rendering a frame ahead into
a buffer (the sprite path) may run at full clock.

### Do not re-guess a sign from the reasoning that produced the wrong one

A one-tile X offset on both layers was patched with -16 on `base_x_scroll`, derived from
`tilemap_x(screen_col) = base_x_scroll + screen_col*16`. Hardware moved the wrong way. The patch was
removed rather than flipped: the derivation was internally consistent and still wrong, so +16 would
be a second guess wearing the first guess's confidence. The real cause was a `gfxrom_req`/
`gfxrom_valid` handshake bug -- not a scroll constant, not addressing math.

### Add runtime A/B switches when the alternative is a rebuild per bisection step

Following `sprite_frame_buffer`'s documented contract (pulse `frame_swap` at vblank, wait for
`swap_done`) stopped the core booting: holding render start across frames left the engine rendering
back-to-back, and it shares the SDRAM arbiter with CPU program fetches. A locally correct fix can
starve a shared resource. It was isolated without rebuilding, using OSD render-disable switches:
forcing both tilemap layers off in the same bitstream still hung, excluding the tilemap change and
the instrumentation and leaving only the sequencing change.

### A swap is not a copy

`spriteram_dbuf` ping-ponged two banks, arguing this was equivalent to MAME's copy as long as the
CPU never touches the render-role bank. That condition held and the claim was still wrong: under
ping-pong the CPU's view alternates between two memories, so any entry it does not rewrite every
frame reads back what was written two frames ago -- including the display list's end-of-list marker.
A long frame that missed the marker inherited a stale one further down and rendered far more
sprites, compounding under load. A real copy removed the ghosting and the per-scene sprite freeze.

## ROM loading: .mra, byte order, deployment

### Prove the interleave against MAME's disassembly offline, before building

"It boots" is weak evidence -- a wrong map can boot far enough to look plausible. Every interleave
here that was *derived* by reasoning about byte order was wrong; the working maincpu map came from
copying a shipped core's idiom (`Bucky O'Hare.mra`). Reconstruct known words from the ROM files and
score them against MAME's disassembly:

```
000404: lea $ffff7000.l,A0   -> 41F9 FFFF 7000
00040A: move A0,USP          -> 4E60
00040C: move.w #$1,D0        -> 303C 0001
000410: movec D0,CACR        -> 4E7B 0002
```

18/18 for one interleave model, 5/18 for the other -- offline, in seconds, no hardware.

### Treat the map-digit rule as mechanical and check it, do not reason about it

mra-tools-c decrements each map digit and emits bytes in that order, so `map="12"` is a pairwise
SWAP and `map="21"` is verbatim.

| MAME region macro | `.mra` form |
| --- | --- |
| `ROM_LOAD16_WORD_SWAP` | `<interleave output="16">` with `map="12"` |
| plain `ROM_LOAD` | bare `<part>`, no interleave |

Getting this backwards un-swaps tile ROMs silently: six `_alternatives` MRAs emitted tiles as a bare
`<part>` while their sprites were correctly swapped, rendering tile layers as garbage while sprites
looked fine. The inverse trap is real too -- tengai's gfx genuinely is plain `ROM_LOAD`, so its bare
parts are correct and must not be "fixed".

### Do not "fix" a loader or file format without hardware evidence of wrong bytes

The maincpu interleave was rewritten on a mental model predicting a corrupt stack pointer. Every
test that seemed to indict it had run against an SDRAM that was never written -- garbage compared
against garbage. The rewrite was also inert: swapping the four-digit maps produced byte-identical
hardware output, i.e. the loader ignored them.

### Verify content against a hardware trace, and know what that does not prove

`scripts/verify_rom_trace.py` takes a decoded on-hardware trace of ROM reads plus the ROM zip,
brute-forces the plausible interleaves, and reports which reproduces the observed data exactly. It
returned 128/128 for the shipped maincpu map, simultaneously proving the SDRAM read path returns
byte-perfect data at those addresses. It verifies *content*, not *address reach*: the trace address
is truncated, so a path aliasing high address bits still scores 100%.

### A hardware-vs-image comparison cannot detect a wrong image

An earlier 128/128 match of a hardware trace against the image assembled from the `.mra` was also
taken as evidence the `.mra` was right. It cannot be -- both sides were built from the same
byte-order assumption. The tell was dismissed: the reset vector had to be byte-swapped in the
analysis script to match MAME's `SP=FFFF8000 PC=00000400`, written off as a capture artifact. It was
real. The CPU received `PC=0x00000004`, executed the vector table as code, hit an illegal
instruction and looped; the "sequential sweep from address 0" that looked like a boot checksum was
the CPU running off the end of the vector table.

### List `<rom index="1">` before `<rom index="0">` when a mod byte gates download-time logic

The mod byte is sent in file order and `mod_board` powers up 0 on every FPGA reprogram. Listed after
`<rom index="0">`, any download-time consumer of it (here `needs_adpcma_swap`) sees 0 for the whole
download and silently does nothing; a runtime-only consumer never exposes this. The swap logic,
transform and address window were all verified correct while the feature did nothing at all -- the
gate opened after the data had passed. Confirmed by ear on hardware, same bitstream, byte last vs
first.

### Gate every deploy on an XML well-formedness check

An edited comment block left a `-->` that had already closed the comment, so new prose landed as
character data -- containing `<- u127`. A bare `<` is illegal XML, MiSTer rejected the file, and the
result was: DIPs gone from the OSD, ROM never loaded, core up on an all-zero image, black screen.
Every symptom pointed at the RTL; the only clue was an on-screen "XML parse" message.

```bash
python scripts/validate_mra.py "releases/*.mra" && <copy to device>
```

That script also flags stray element text, which is how a prematurely-closed comment shows up.
MiSTer's parser is *more lenient* than a strict one (this file carried `--` inside comments and two
leaking comment blocks for a long time), so "it loaded before" is not evidence of well-formedness.

### Force a genuine reload when testing an `.mra` change

Re-launching an already-loaded game reuses the cached ROM, so an `.mra` edit alone produces a
byte-identical trace -- which nearly caused a correct fix to be discarded. Bounce through the menu:

```
POST /api/launch {"path":"/media/fat/menu.rbf"}   # then wait
POST /api/launch {"path":"/media/fat/_Arcade/.../Game.mra"}
```

### Put the `.rbf` in the top-level cores directory

`.mra` files reference it via a bare `<rbf>Arcade-Psikyo</rbf>` tag and MiSTer resolves it by
prefix-matching filenames in `/media/fat/_Arcade/cores/` only, not a path relative to the `.mra`. A
misplaced `.rbf` gives a silent flash-and-return-to-menu, before ROM loading begins.

### Do not hand-write a `.CFG`

`/media/fat/config/<setname>.CFG` is the whole 128-bit status word, little-endian (byte N holds
`status[8N+7:8N]`), and the `.mra`'s `<switches>` bytes live in that same word (byte0 ->
`status[23:16]`, and so on upward). Writing 16 bytes with only a debug bit set zeroes every DIP,
which here silently enabled Service Mode. Use a read-modify-write script; the hand-written mistake
was made twice. Per-game defaults come from each `.mra`'s own `<switches default="...">` -- that
attribute is the authority, not prose in a doc. A DIP value that looks harmless can hang a game:
gunbird's boot polls `$C00004` bit 7 and spins until it clears, so a `0xFF` region byte never boots.

### Make the all-zero configuration the correct one

A fresh or missing `.CFG` is all zeroes, so any OSD option whose enabled state is required for
correct behaviour must be bit-inverted with its OSD order written to match (here `status[51]`,
"Sound IRQ", listed `On,Off`). Otherwise every first-run user gets the degraded path.

## MiSTer integration: reset and ioctl download

### Never hold the memory path in the core reset

MiSTer holds core `RESET` asserted for the ENTIRE ROM download, so anything in the memory path that
resets on `RESET` is dead for the whole transfer. Passing the core's composite reset into the SDRAM
backend pinned `sdram_download`'s FSM in `D_IDLE`: `dl_req` never asserted, the arbiter never
selected the download path, and not one `CMD_WRITE` reached the chip -- while the HPS delivered all
`0xE00000` bytes and the FSM's accept condition looked perfect. SDRAM was never written; every read
returned power-up contents.

Keep two reset domains: `core_reset = reset | ioctl_download` gates CPU and video only; the memory
backend keeps the plain `reset`. Signature: a downstream FSM stuck in idle while its trigger input
is visibly pulsing correctly.

### Measure at the pins, not at the intent

The decisive measurement for the reset bug was counting real commands on
`{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE}` (`CMD_WRITE = 3'b100`) -- top-level signals. Delivery counters
and FSM accept-condition counters both looked perfect; only the pin count revealed zero writes.
Measure the last observable stage, never an internal signal that merely implies it.

## Memory transport: req/valid contracts, latency, byte order

### Give a registered RAM its full read latency before consuming the data

An FSM that registers a RAM address in one state and reads the data in the next state gets the
PREVIOUS address's data: the RAM only samples the address at the end of the state that set it, so
the result is not valid until one state later. This is the same stale-read class as the duplicate
transaction below, and it is easy to write because the code reads as if the address were applied
combinationally.

The row-scroll table showed it: every scanline was scrolled by its PREDECESSOR's table entry,
because `S_ROWSCROLL_WAIT` consumed `rowscroll_data` the cycle after latching `rowscroll_addr`. A
smoothly varying table hides this completely -- it only becomes visible where consecutive entries
differ sharply, so it can sit unnoticed in games whose scroll changes gradually. The port's own
comment already documented "1-cycle synchronous read latency"; the FSM simply did not honour it.

Two habits that catch it: state the latency in the port comment AND spend the wait state, and
write the testbench RAM model as a registered read (`always_ff ... rdata <= mem[addr]`) so a
behavioural model cannot mask it. A testbench that never exercises the feature is the other half
of the problem -- the existing line-engine bench ran with row-scroll disabled throughout, so this
path had no coverage at all.

### Deassert a request combinationally on `valid`

`tilemap_line_engine` cleared `gfxrom_req` one clock AFTER `gfxrom_valid` (registered clear in
`S_GFXROM_WAIT`), while `sdram_phy.sv` returns to `S_IDLE` on the valid cycle itself and samples the
still-high stale request -- launching a duplicate transaction for the address it just served. Every
later response the engine consumed belonged to the previous request: position N rendered cell N-1's
tile shape with N's own correctly latched colour, appearing as a one-cell offset plus a
wrong-palette bug. Deterministic protocol bug, not a timing violation.

```systemverilog
assign gfxrom_req = gfxrom_req_r & ~gfxrom_valid;
```

Proved by `tb_tilemap_screen_sdram.sv`, which reproduced the hardware screen pixel-for-pixel and
whose transaction trace showed the phy serving the previous request's address from the second fetch
of every line. Live JTAG ISSP pokes into VRAM with the CPU paused had already established the
chained N/N+1 dependency in two games.

### Hold every request until acknowledged

A request/ack round-robin arbiter needs every port on a hold-until-acknowledged contract, not a
one-shot pulse: a pulse arriving while the arbiter services another client is silently lost. Applies
uniformly across `ddram_arbiter`, `sdram_arbiter5` and the HPS download path -- `ioctl_wr` from
`hps_io` is a genuine one-shot and needs a wrapper (`sdram_download.sv`) converting it with
`ioctl_wait` backpressure.

### Treat any direct, non-arbitrated connection to a req/valid transport as suspect

`sdram_phy.sv` asserts `valid` and returns to `S_IDLE` on the same cycle. Arbitrated consumers get a
cycle of margin because `c_valid` asserts one cycle before the arbiter's own state returns to idle;
a single-client port wired straight to the phy ("no arbiter needed for one client") skips it. Sprite
gfxrom's dedicated Port 1 did exactly that and silently returned the previous transaction's stale
data under contention -- not a hang, just wrong data, read on hardware as sprite corruption. Fixed
with a single-client pulse shim (`SP_IDLE`/`SP_ISSUE`/`SP_WAIT`) reproducing the arbiter's margin.
Third occurrence of this defect class in one project.

### Clear a request-tracking flag on the bus cycle ending, not on the data-valid pulse

A `rom_pending`-style flag must clear when the CPU's bus cycle actually ends, if the CPU can hold it
open longer than the fetch (real 68k cycles hold `as_n` low for several cycles after DTACK
releases). Clearing early fires a spurious second request for data already latched; under
multi-client contention another client can win that slot and overwrite a shared read-data register
before the original cycle finishes. Symptom looked like SDRAM corruption; cause was the CPU
wrapper's own request lifecycle. Check every request-tracking flag against the bus protocol's cycle
length, not its own "data arrived" signal.

### Capture read data on the valid pulse -- nothing in the path latches it

The whole path from `sdram.sv`'s `dout` to the CPU data bus is combinational and valid is a
one-cycle pulse: `dout0`/`dout1`/`dout2` come from one shared register (upstream does this too),
`sdram_arbiter5` assigns `c*_data`/`c*_valid` combinationally, and `sdram_narrow_bridge` selects its
word with no register anywhere. `maincpu.sv` got away with reading combinationally only because
TG68K.C re-captures `DATA` on every clock edge while parked in a wait state, so the one-cycle window
always landed -- an alignment that holds by exactly one cycle. **Any change to how often a consumer
samples (a clock enable, another clock domain, an extra pipeline stage) requires latching both the
data and the ready/DTACK level first.** Fixed with `rom_data_l`/`rom_ready` held until the CPU drops
`as_n`; once captured, the word cannot be clobbered by another port.

`dout0`/`dout1`/`dout2` being literally the same register makes this a correctness requirement, not
a style point: sampling later than your own valid/ack cycle reads another port's in-flight data.
Testbenches must obey the same discipline -- one that samples outside each port's ack-triggered
branch shows 100% failures that look like an RTL bug.

### DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU

A core stepping at 16 MHz inside an 85.909091 MHz fabric looks at DTACK about once every 5.4 cycles;
a one-cycle assertion is missed on nearly every access and the bus cycle hangs forever. Check every
ready/ack feeding a gated core before enabling the gate.

### Fix byte order at the seam, with a dedicated adapter

Endianness bugs live at the seam between two independently correct modules. `sdram.sv`'s burst
capture packs bytes in ascending-address order; gfx-ROM consumers assumed MAME's MSB-first format;
the maincpu program ROM needs big-endian while `sdram_narrow_bridge.sv`'s generic word path is
little-endian (correct for genuinely little-endian regions like spritelut). Add a small adapter at
each seam rather than changing a shared module's convention out from under its other, correct
consumers. Any test using uniform or all-zero content is invariant under byte order and cannot catch
this: use synthetic data for a cheap wiring smoke test, but budget a real-content integration test
before trusting the result.

### Choose SDRAM over DDRAM for hard real-time fetch budgets

MiSTer's docs describe `DDRAM_*` as for "non-critical time purposes", with latency that can far
exceed the typical ~20 cycles and an unbounded worst case. `tb_video_pipeline_ddram.sv` measured ~26
combined cycles against a 16-cycle-per-tile budget under two-consumer contention. `SDRAM_*` gives
three independent ports at bounded ~6-7 cycles. If a design starts on DDRAM for convenience, budget
time to pivot rather than patching throughput afterwards.

### Verify a burst extension against a command-decoding chip model, not a latency stub

Adding burst-4 to a controller with no burst support needs a model that decodes
`nRAS`/`nCAS`/`nWE`/`SDRAM_A`. That caught three bugs: the row/column address split needed swapping
(a hardware burst auto-increments the *column*, so four consecutive word addresses must land in four
consecutive columns of the same row -- the non-bursting upstream had it the other way, which only
matters once bursting exists); the chip model silently ignoring the `DQML`/`DQMH` write mask; and an
off-by-one in burst-read CAS timing (a dropped `+1` registration-delay margin).

### Size a prefetch buffer for correlated consumers, not average bandwidth

Two tilemap layers with identical scanline timing request in near-lockstep, so a 2-entry ping-pong
buffer absorbs only one simultaneous loss and roughly one tile in five stalled. A parameterized
N-entry ring buffer (interface unchanged) absorbed them. That is a fix for the tested contention
pattern, not a guarantee; an independent fetch-ahead domain or pipelined controller remains the
complete answer.

## When simulation passes and hardware fails

### Re-run the failing case with the production transport in place of behavioural models

The `gfxrom_req` duplicate transaction fired in module-level simulation too, but the short-latency
behavioural ROM model returned its response while the FSM was between states, so it was silently
dropped. The real controller's ~12-cycle latency lands the duplicate in the next wait state, where
it corrupts the result. That is why every module-level sim passed while hardware failed. The
testbench that found it wired `psikyo_sdram_top` verbatim plus `sdram_chip_model_wide` into the
screen path. When sim and hardware disagree and timing is clean, swap behavioural models for the
real transport stack before blaming synthesis.

### Ask of every stimulus whether it is the shape the real system produces

`tb_maincpu.sv` pulsed `vblank` for one clock; hardware holds it for the whole 38-line blank
(~205,000 clk_sys cycles). That hid a genuine `maincpu.sv` bug for the whole project: the IRQ logic
was `if (vblank) set; else if (iack) clear;`, giving *set* priority, so an acknowledge arriving
while vblank was still high -- always the case on hardware -- was discarded. `irq_pending` never
cleared, `ipl` stayed at 4, and the CPU re-entered the ISR after every `RTE`. With a one-clock pulse
the acknowledge always landed after vblank fell, so the test passed every time.

Same blind spot, two siblings: a testbench drives its own reset and download sequencing, so it never
reproduces MiSTer holding RESET across a transfer, and `ioctl_index` was hardcoded to 0 so an index
mismatch could never surface.

### Give a held interrupt line's acknowledge priority

Match MAME's `irq4_line_hold`: assert on the rising edge of the source, hold until acknowledged, and
give the acknowledge priority. Ask of every level-sensitive input whether it is still asserted when
the consumer responds; if so, set-vs-clear priority is a real design decision.

### Check static timing before pursuing any hardware-vs-simulation divergence

The cheapest check, and it was skipped for days. See "Timing closure".

## Testbench discipline

- **Use `do @(posedge clk); while (signal);`, never `while (signal) @(posedge clk);`.** The latter
  races an `always_ff` updating the same signal on the same edge and either deadlocks on a signal
  that already cleared or returns before a transaction started. Recurred independently in
  `ddram_phy_tb`, the `sdram_download` integration test and the `psikyo_sdram_top` integration test
  before being recognised as systemic.
- **Grep the log for `readmem` before touching RTL when a testbench fails wholesale.** `vsim`
  launched from the wrong directory made `$readmemh` find nothing, the ROM stayed all zeroes, and
  every check failed -- reading exactly like a catastrophic RTL regression. ModelSim reports it as
  `** Warning: (vsim-7) Failed to open readmem file`, not an error. Failure in *every* check rather
  than one is the signature.
  The underlying cause is that `$readmemh` paths are relative to the simulator's CWD, not the
  testbench file: `tb_maincpu.sv` must run from the repo root, `tb_psikyo_core.sv`/`tb_psikyo_top.sv`
  from their own subdirectory plus `vmap work ../../work`.
- **Write preloaded vectors and tables AFTER `$readmemh`, never before.** `tb_maincpu.sv` installed
  the level-4 autovector at byte `0x70`, then `$readmemh`'d an image spanning that address whose
  empty `0x70`-`0xFF` region zeroed it. The CPU took the interrupt correctly, fetched the correct
  vector address, read zero, jumped to `0x00000000` and executed zeroes into an illegal instruction.
  This was recorded for weeks in two documents as a TG68K.C exception microcode bug and used as the
  standing reason interrupts "could not be trusted".
- **Confirm which column is address and which is data before blaming a CPU.** The trigger for that
  wrong conclusion was reading `0x00000000` in a bus trace as the fetch address; it was the *data*
  read back from the correct address `0x70`. Suspect a zeroed vector table long before microcode.
- **Do not assert on a sticky error output that has a benign first trigger.** `fetch_overrun` fires
  unavoidably on the first active line after reset (no prior hblank to prefetch into) and once
  latched is indistinguishable from a real later failure. Replicate the DUT's trigger condition with
  a non-sticky per-cycle check instead.
- **Re-run the regression on a clean stash before debugging your change.** A missing or stale
  fixture looks identical to a real regression; `git stash` plus a re-run rules it out cheaply.
- **Write a smoke test (elaborate, run N cycles, check for crash and X-propagation) before a
  functional test** on any new top-level integration -- it catches port-width and wiring mistakes
  cheaply.

## Timing closure

### Open the STA summary before believing any hardware-vs-simulation divergence

Quartus reports "Fitter was successful" on a design that grossly fails timing; nothing in the
default flow fails, warns loudly, or blocks the `.rbf`. This project shipped an `.rbf` whose main
clock domain had -8.879 ns setup slack and -21,031 ns TNS -- thousands of failing endpoints, a worst
path nearly twice the clock period -- while every log line said "successful" and "0 errors". It
appears only in `output_files/<rev>.sta.summary` / `<rev>.sta.rpt`, which nothing forces you to open.

### Read the Fmax Summary first

`emu|pll|...divclk : 48.74 MHz` against an 85.909091 MHz clock is instantly diagnostic and needs no
path analysis. It is the highest-value number in the report.

### Treat "correct in sim, wrong on hardware, reproducible, insensitive to interface tuning" as a timing violation until proven otherwise

The symptom set was: boots but reads back wrong data; roughly half of golden-ROM comparisons
mismatch; reproducible across power cycles; unaffected by SDRAM_CLK phase; 100% correct in ModelSim
with identical ROM data. All of those are also what a timing failure produces -- deterministic
because placement is fixed per `.rbf`, phase-independent because the failing paths are internal
fabric the memory clock never touches, invisible in RTL simulation because simulation has no
propagation delay. Interface tuning (clock phase, drive strength, IOE registers) only moves
*external* margins by a fraction of a clock period; if a change that size makes no difference at
all, the problem is not at the interface.

### Discard measurements taken while the design fails timing

The "~51% of ROM words match" figure and the original SDRAM_CLK phase sweep were both taken while
the entire clk_sys domain failed by 8.9 ns, and both were used to rule the memory interface *out*.
Re-run any measurement that predates a timing fix.

### Get the failing paths with a `quartus_sta` Tcl run

The default `.sta.rpt` has only summaries, and the Timing Closure Recommendations panel is HTML-only
so it is empty in the text export. See `scripts/sta_failing_paths.tcl`:

```tcl
project_open Psikyo -revision Psikyo
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c   ; # NOT -slow_model / -speed 7
read_sdc
update_timing_netlist
report_timing -setup -npaths 50 -detail summary -from_clock $ck -to_clock $ck -file out.rpt
```

`create_timing_netlist -speed 7 -slow_model` is rejected outright, and the useful error ("Values
entered did not match any valid operating conditions") appears above the generic Tcl failure. Run
`-detail summary` first: 50 summary rows immediately showed every failing path shared one module,
which full-path detail would have buried.

### Never let a multicycle constraint touch a posedge-to-negedge path

A constraint matching `{*TG68K:*|*}` sweeps the wrapper's falling-edge registers into the collection
and grants a HALF-cycle path (~5.8 ns at 85.909091 MHz) two or four FULL cycles -- up to ~46 ns. The
Fitter routes it that slowly, the timing report stays clean, and the design fails only on silicon.
Two registers caught this way were `waitm` (the DTACK sample) and `data_akt_e` (which gates the DATA
tri-state), so relaxing them corrupts bus handshaking directly. If a multicycle is needed at all,
scope it to a block verified single-edge and explicitly `remove_from_collection` every falling-edge
register from BOTH ends.

### Know that the stock MiSTer `.sdc` constrains nothing external

`derive_pll_clocks` + `derive_clock_uncertainty` is the entire stock file. It constrains internal
register-to-register paths (which is how the CPU failure was caught) and leaves every external
interface, including all of SDRAM, unanalyzed. Non-empty Unconstrained Paths and Unconstrained I/O
panels are normal for MiSTer and not by themselves a bug -- but "timing passed" says nothing about
the memory interface.

## CPU cores (TG68K.C, T80)

### Budget for the 68k core to be the Fmax-limiting block

Measured Fmax on the real post-fit netlist, Cyclone V speed grade 7: 48.74 MHz. All 50 worst-slack
paths in the design were inside `TG68KdotC_Kernel` -- the `altsyncram` register file and the
`regfile_rtl_*_bypass` network, driven from `use_direct_data` and `exec[*]`, needing ~19.6 ns.
Nothing else (video, SDRAM, sound) failed timing at all. TG68K.C also has no clock-enable input of
its own to protect you.

### Instantiate `TG68KdotC_Kernel` directly and own the bus interface

`TG68K.vhd` is an async-68000-bus adapter, not the CPU: it wraps the core in a bus-protocol emulator
that assumes `CLK` *is* the CPU clock, hence its `falling_edge` registers (`as_e`, `rw_e`, `uds_e`,
`lds_e`, `clkena_e`, `data_akt_e`, `cpuIPL`, `waitm`, `E`). Slowing it down means fighting its
design. The kernel is entirely rising-edge (verified: zero `falling_edge` occurrences) and exposes
`clkena_in` for exactly this. `mist-devel/plus_too`'s `tg68k.v` is the canonical example:

```verilog
wire tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01);
```

Its own state machine handles DTACK and stalls the CPU purely by gating `clkena_in`; the interface
is `busstate`/`addr_out`/`data_in`/`nUDS`/`nLDS`/`nWr` (`busstate == 2'b01` means no memory access,
so the CPU free-runs). Nothing inside the core is modified.

What was tried instead and failed: adding `ext_clkena` to `TG68K.vhd` and gating every clocked
process. It appears to work (`tb_maincpu` passed, the real-ROM sim booted) but the two clock edges
need two separate enables -- a rising-edge register samples the enable held during the *preceding*
period, so one shared enable runs each emulated CPU cycle's halves in the wrong order -- and the
timing report then needs a `set_multicycle_path` to accept the result, which is where it turns
dangerous. Four layers of scaffolding on a battle-tested core, and it still did not boot.

### Derive the clock-enable ratio exactly rather than rounding

clk_sys here is the real 14.318181 MHz screen XTAL x 6 = 945/11 MHz and the 68EC020 wants 176/11
MHz, so the enable rate is exactly 176/945 and a Bresenham accumulator hits it with zero error. The
tempting integer divides are meaningfully wrong: /5 is 7.4% fast, /6 is 10.5% slow. (Alternatively
drop clk_sys to 42.954545 MHz = 14.318181 x 3, keeping the pixel divide exact at 6:1 and landing
under TG68K's measured Fmax outright.)

### Do not rely on Quartus resolving an open-collector net the way ModelSim does

`TG68K.vhd` drives `RESET <= '0' WHEN nResetOut='0' ELSE 'Z'` (same for `HALT`) because the core can
self-assert reset, while the wrapping SystemVerilog also drives these lines -- a genuine
open-collector bus, which `tri1` models correctly in simulation. Quartus 17.0 instead emits
`Warning (13048): Converted tri-state node "..." into a selector`, and that selector's behaviour for
the both-released-to-Z steady state is wrong on silicon: the resolved value sticks low, holding
permanent reset. Confirmed by a live hardware debug tap (VGA-colour-coded build) showing the kernel
reset stuck asserted on a DE10-nano while the same RTL simulated correctly.

Fix pattern: do NOT make either side of the shared net non-tri-state. Add a separate, single-driver
signal and OR it into the downstream computation that needs the correct value -- a new
`ext_force_run` port with `cpu1reset <= (RESET OR HALT) OR ext_force_run;`. `1 OR anything = 1`
forces the correct steady state without creating a second driver.

Then check every consumer, not just the first found. The wrapper's own bus-cycle state machine used
the same raw `RESET` as its async reset, so fixing only the kernel's `nReset` left the CPU out of
reset with bus-cycle generation still stuck. Signature of "fixed one consumer, missed another": the
CPU stops asserting reset but still generates no bus activity.

### Expose a new port rather than a hierarchical reference for a debug tap

SystemVerilog hierarchical references into VHDL internals work in ModelSim but do not elaborate for
Quartus at any depth -- both `u_cpu.cpu1reset` and `u_cpu.cpu1.Reset` gave
`Error (10207): can't resolve reference to object`. Add a real output port to the vendored entity;
unconnected new ports at other instantiation sites are legal, so no other caller needs touching.

### Add explicit zero initializers to vendored VHDL signals before simulating real programs

`TG68K_ALU.vhd`/`TG68KdotC_Kernel.vhd` have many `std_logic`/`std_logic_vector` signals with no
default. ModelSim's `'X'` propagates through arithmetic from time 0 and can cascade into multi-GB
allocation failures or SIGSEGV once a real program (not a four-instruction spike) exercises enough
logic. Known upstream issue (TobiFlex/TG68K.C#21); 123 signals initialized here. Simulation fidelity
only -- same class of fix as `sdram.sv`'s uninitialized `state`/`ack0..2`.

### Exercise the ISA extensions you depend on, deliberately

The Phase 0 spike ran 68020-only opcodes (MULU.L, DIVU.L, scaled-index addressing, BFEXTU) before
further work was committed. Two apparent "core bugs" during that spike turned out to be testbench
mistakes.

### Derive `WAIT_n` timing from the CPU's internal T-state behaviour, not external bus inference

A T80 ROM-interface design based on top-level signal tracing alone hit a reproducible bug -- a
multi-byte opcode whose own read M-cycle follows two operand fetches corrupted the destination
register, with no visible access to the target address anywhere in the external trace -- and was
reverted. Reading `T80.vhd`/`T80se.vhd` gave the facts that mattered: `TState` freezes while
`WAIT_n` reads 0 (resampled every cycle, no edge logic), data is captured on the exact edge that
condition first goes true, and `RD_n`/`MREQ_n` are registered outputs defaulting high every cycle,
so there is always a one-cycle gap between M-cycles even within one instruction -- which a
same-cycle edge-detector design cannot assume. The fix was a level-tracked `rom_pending` gated by a
glitch-free combinational `is_rom_read` level, confirmed by re-running the failing scenario with
hierarchical access to the core's own `MCycle`/`TState`, not by "the test passes now".

## Quartus synthesis gotchas (not visible in ModelSim)

- **Non-blocking assignments to block-local (`automatic`) variables are rejected**, even with the
  `static` keyword, in a pattern that compiles fine under ModelSim:
  `Error (10959): illegal assignment - automatic variables can't have non-blocking assignments`.
  Move them to module-level declarations, then re-run the full ModelSim regression.
- **Multi-driver conflicts on a shared tri-state net are a hard, unsynthesizable error**, not an
  ambiguity Quartus resolves. Making either side non-tri-state while the other still drives gives
  `Error (13076): "..." has multiple drivers due to the non-tri-state driver "..."`, and it can
  surface at a much deeper signal than the one you touched (fixing `cpu1reset` surfaced a conflict on
  `TG68KdotC_Kernel:cpu1|syncReset[3]`). Use the separate-signal OR pattern above.
- **A non-power-of-2 modulo synthesizes as a slow generic iterative divider and can dominate timing
  closure.** `sprite_index <= sram_data % 16'd768;` produced the worst timing path in the whole
  design (`Mod0|auto_generated|divider`), buried inside `sprite_display_list_walker.sv` and not an
  obvious suspect from a read-through. An explicit N-stage conditional-subtraction chain (subtract
  decreasing power-of-2 multiples of the modulus when they fit) kept the same one-cycle
  combinational timing and cut worst-case setup slack by 81%. Read `report_timing`'s worst path
  rather than guessing which module is at fault.
- **Negative PLL phase shifts are not legal for every PLL configuration.** `quartus_fit` rejected
  `-3000ps` outright; only `0ps` and positive values in fixed steps (~132.275 ps here) are legal.
  Convert to `period - abs(shift)`, rounded to the nearest legal step Quartus names in its own error.
- **Driving a dual-port RAM's second read port can silently REPLICATE the whole array.** A block
  RAM has one write port and one read port per physical port; asking for two independent read
  addresses plus a write is a shape the M10K cannot provide, so Quartus duplicates the memory and
  writes both copies. Symptom: a 128KB work RAM reporting 2,097,152 block memory bits, about 102
  extra M10K, and a design that had fitted the day before failing with
  `Error (170048): ... needs more than 553 to successfully fit`. The trigger looked harmless -- the
  second port had been tied to a constant address and was therefore optimized away entirely, so
  hooking a real address to it was read as "using a port that was already there". Give the new
  consumer the EXISTING port instead when the two can never collide (here the consumer only touched
  RAM with the CPU paused). Check `Block Memory Bits` per hierarchy node in the map report against
  the array's arithmetic size before assuming an unused port is free.
- **A design can be BRAM-bound while logic sits at 40%.** Budget features in M10K blocks, not ALMs.
  Bit occupancy is the number that matters: no memory packs at 100%, so a design at ~95% of the
  device's block memory bits cannot be made to fit by repacking, only by removing memory. Repacking
  a 12-bit-wide array as 8+4 to land on native widths is a real technique, but it is worth nothing
  if the true cause is an array that should not be there at all -- confirm where the bits went
  before restructuring anything.
- **`set_instance_assignment -name RAMSTYLE` is rejected by the .qsf parser in Quartus 17.0**
  (`Error (125048): Error reading Quartus Prime Settings File ... line N`, which aborts the whole
  project open). Use the HDL `(* ramstyle = "..." *)` attribute instead.
- **`quartus_map` (Analysis & Synthesis only) is a fast pre-check** (~2-3 min vs ~5-6 min for a full
  compile) for whether an RTL change even elaborates. Quartus auto-parallelizes across cores;
  ModelSim in this edition is single-threaded.

## Debug instrumentation: how not to fool yourself

- **Never reset a debug counter with the reset you are investigating.** Two measurements read
  `0x000000` and were reported as findings before it was noticed the counters were cleared by
  `reset`, which is asserted for the whole measured window. Declare debug counters with `= 0`
  initialisers and no reset; Quartus powers registers to zero, so what they show is what genuinely
  happened since configuration.
- **Pair every "bad event" counter with a "total events" counter.** A zero can mean "did not happen"
  or "was never allowed to count"; counting only dropped bytes cannot tell those apart.
- **Sample registered signals, not combinational ones, and prove the probe on a known-good
  configuration first.** A tap on combinational `cpu_data` sampled at `cpu_ce && !as_n && !dtack_n`
  appeared to show the CPU latching byte-skewed data -- compelling and false. The same probe in a
  simulation that demonstrably boots showed the same skew. If a new probe reports a fault on a
  known-good setup, the probe is the fault.
- **Never let a probe's step size share a factor with the period you are measuring.** A BRAM tracer
  skipping `window * 256` events returned byte-identical captures for windows 0, 8 and 15 (skips of
  0, 2048, 3840), equally consistent with a CPU resetting every 256 reads and a read path aliasing
  every 256 words. The step is now `window * 8191` -- odd, so it cannot alias with a power-of-two
  period. When a probe gives the same answer at every setting, suspect the step.
- **Capture the full address.** Packing only `addr[7:0]` into a 24-bit pixel made a genuine linear
  sweep through ROM look exactly like a read path dropping its high address bits, destroying the
  distinction between "progressing" and "stuck". If address and data do not fit together, use two
  buffers strobed by the same event so entry N of each describes the same bus cycle.
- **VGA-colour-override builds answer yes/no hardware questions without a logic analyzer.**
  Overriding `VGA_R/G/B` with a solid colour gated by an internal signal turns "is this condition
  true on real hardware" into one unambiguous screenshot -- used to confirm the video datapath works
  at all, then for a 3-way readout of CPU ROM-fetch activity via sticky latches and a 4-colour
  readout adding live kernel-reset state. Remove all `dbg_*` ports and wiring once the bug is fixed.
- **JTAG ISSP pokes test a hypothesis on live hardware without a rebuild.** With the CPU paused,
  `scripts/write_vram1.tcl` wrote single VRAM words and the screen response was read directly; that
  established the chained N/N+1 dependency behind the tilemap handshake bug, in two games, before
  any RTL changed.
- **Do not blind-enable an interrupt path you have no way to verify.** Enabling the YM2610 timer IRQ
  to the Z80 took its ROM-fetch counter to zero immediately -- a complete lockup, not "runs but
  silent", and a hang is a worse regression than the symptom it was meant to fix. Expose the CPU
  state needed to read the outcome (`halt_n`, ideally PC) in the same build that enables the path.
- **A sound CPU that programs the chip once and then goes quiet is an interrupt-path symptom.** 46
  YM2610 register writes were measured immediately after launch and zero over a later 15-second
  window: the init burst runs from boot code, and the chip's own timer interrupt -- how arcade
  drivers sequence music -- was not reaching the CPU. (The eventual cause was transport bugs
  elsewhere; the IRQ is required for music.)

## Hardware bring-up (MiSTer / DE10-nano)

- **The DE10-nano SDRAM pinout has an authoritative in-repo reference; do not go to the web.** The
  `.qsf` does `source sys/sys.tcl`, which is the vendor template's own SDRAM pin block; cross-check
  against `output_files/<rev>.pin`, which records where every signal actually landed post-fit (all
  38 matched across all three). The `.qsf` also *restates* every location assignment after the
  `source` line, because the IDE re-saved the project -- identical values today, but a future
  `sys.tcl` update would be silently overridden.
- **Audit an inherited `.srf`: it suppresses messages worth seeing.** This one came from another
  core, hides 15705 ("Ignored locations or region assignments") which could mask a dropped pin
  assignment, and still references a file that does not exist here.
- **Fitter warnings 176250/176251 ("Ignoring invalid fast I/O register assignments") are almost
  always benign, and the Ignored Assignments panel names exactly which** -- here pins already
  occupied by a DDIO primitive, tied to constants, or driven by a raw PLL output. Do not read them
  as evidence about the SDRAM *data* path: confirm instead by counting register-packing entries,
  which showed 16/16 fast input, output and output-enable registers packed on `SDRAM_DQ`.
- **The SDRAM_CLK phase shift is legitimate but a poor first suspect.** `-3 ns` is the standard
  MiSTer convention, expressed here as the equivalent positive `"8598 ps"` because this `altera_pll`
  rejects negative values. Sweeping it to `0 ps` gave byte-identical results, which was the clue the
  fault was not at the memory interface at all. Revert diagnostic PLL values immediately.
- **`/dev/fb0` is the ARM-side OSD overlay surface, not the FPGA's composited game video.** Do not
  use it as evidence about the core's video pipeline; use the screenshot API, which captures
  scaler-composited output.
- **MiSTer Remote API** (wizzomafizzo/mrext, port 8182) is documented, and its Go source is worth
  reading rather than guessing. `POST /api/launch {"path": "<abs path>"}` writes `load_core <path>`
  to MiSTer's own command-interface device file, the same primitive the menu uses.
  `POST /api/screenshots` returns an effectively empty body regardless of success: poll for a new
  file under `/media/fat/screenshots/<core-shortname>/` instead, often several seconds late.
- **An automated deploy-then-launch script needs an explicit settle gap** that manual multi-step
  testing gets for free. Back-to-back deploy then launch hit a real race (the new `.rbf` not
  reliably flushed) that never appeared when the same steps ran as separate manual calls seconds
  apart; add `sync` after deploy plus a short sleep. Generally, when a race is suspected in an
  automated tool, re-run the exact previously working manual sequence before assuming the deployed
  binary is stale.
- **`plink.exe`/`pscp.exe` are the practical non-interactive SSH/SCP path on Windows** (OpenSSH has
  no clean non-interactive password auth, `sshpass` is usually absent):
  `echo y | plink.exe -ssh -pw <password> user@host "command"`, where `echo y` auto-accepts an unseen
  host-key prompt.
- **MSYS/Git-Bash silently mangles POSIX-looking arguments** such as `/media/fat/...` into Windows
  paths when passed to a non-MSYS program, which made an automated deploy launch a garbage path with
  no error. Prefix invocations with `MSYS_NO_PATHCONV=1`.

## Tooling and workflow (Quartus, ModelSim, and the shell around them)

- **Working directory does not reliably persist into backgrounded shell commands.** Launch every
  Quartus/ModelSim invocation as `cd <project dir> && <tool>` in one command line, or make it
  cwd-independent; for Tcl-driven tools put the `cd` inside the Tcl script. Symptoms:
  `Error (23018): Tcl Script File ... not found`, or
  `Error (12007): Top-level design entity "Psikyo" is undefined`.
- **`quartus_sta`/`quartus_map`/`quartus_sh` are not on `PATH`**; invoke by full path. Two Quartus
  installs exist on this machine; the project was built with 17.0.2, and using the other means the
  post-fit database will not match.
- **Never run Quartus wrapped in `nohup ... &`.** It detaches, the tool call reports "completed"
  immediately, and the real process runs untracked. Launch the tool directly and let the harness
  background it.
- **Never switch git branches while a Quartus process is reading the source tree.** It silently kills
  the run, leaving a truncated log that looks like a tool crash.
- **Never leave duplicate tool instances running against the same project.** Overlapping
  `quartus_map` runs corrupt the shared log; two `vsim` instances on the same testbench write the
  same output file, and killing one can take the other down (`Fatal: vish lost connection to vsim
  process`). Check before every launch.
- **Sweep for orphaned `vsimk.exe` kernels at the start of any session that runs simulations.**
  Killed ModelSim runs leave kernels spinning at 100% CPU indefinitely, across days -- six were once
  found from the previous day having burned ~90,000 CPU-seconds. Their working set drops to ~42-50 MB
  versus ~180 MB for an active kernel, so size is not a liveness signal, and `tasklist` has no CPU
  column:

  ```powershell
  Get-Process vsim,vsimk | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime
  ```

  `taskkill //PID <n> //F` fails against these; `Stop-Process -Force` succeeds. Left alone they
  starve every later simulation, which then looks like the new run being pathologically slow.
- **The ModelSim `work` library lives at the repo root**, mapped by each testbench directory's
  `modelsim.ini` via `work = ../../work`. Run `vsim` from the testbench directory so it is picked up.
  After an RTL change recompile only the changed files (`vcom`, `vlog -sv`) rather than rebuilding.
