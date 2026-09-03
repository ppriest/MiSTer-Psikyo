# Savestates — feasibility study and design

Status: **investigated, not started.** This document exists to answer "can this core have
savestates, and what would it cost", so that the answer is on record before anyone opens an
editor. Every claim below is checked against this repository's actual RTL or against the
referenced upstream source; where something is unverified it says so.

References used:
* MiSTer savestate API — <https://mister-devel.github.io/MkDocs_MiSTer/developer/savestates/>
* MAME `src/mame/psikyo/psikyo.cpp` (`machine_start`, lines 1071-1103) for what state the
  driver itself considers meaningful.

## Verdict

Feasible, in tiers, and the tiers are decided by one component.

| | Verdict |
|---|---|
| Framework plumbing (DDR3 slot, control word, OSD) | Straightforward. No `sys/` changes, no new top-level ports. |
| RAMs (work RAM, VRAM, spriteram, palette, vregs, sound RAM) | Straightforward, and there is already a working precedent in this tree (`rtl/hiscore.v`). |
| Z80 sound CPU | Free — the vendored T80 already has a full save **and** restore port. |
| 68EC020 main CPU | Tractable without forking TG68K.C, via a self-dump stub. One spike must confirm it. |
| s1945 PIC protection FSM | Trivial; 1:1 with MAME's own save list. |
| OPL4 (Strikers/Tengai audio) | Straightforward — we wrote it, the state is enumerable. |
| **YM2610 (jt10)** | **The blocker.** No state port, and the state is in circulating shift registers, not a register file. |

Recommendation: ship **Tier 1** — exact CPU, RAM and video state; audio restored by replaying the
YM2610 register file rather than its pipeline. A note held across the save point re-attacks on
load, so the player hears a fraction of a second of wrong music and then correct audio. Defer
**Tier 2** (bit-exact FM continuity), which needs a cross-cutting fork of jt10.

## 1. What the framework actually provides

Per the MiSTer developer docs, the savestate API is thinner than its name suggests:

* The core declares support in `CONF_STR` as `SS{base addr}:{size}` — e.g. `SS3E000000:40000;`
  (256 KB per slot). Base is conventionally in the `0x3000_0000` range.
* Exactly **four** slots. That is a firmware constraint, not a core choice.
* Each slot opens with a 64-bit control word: bits `[31:0]` are a **change detector** — the core
  pokes it and the firmware persists the slot to disk with no OSD interaction — and bits `[63:32]`
  are the **savestate size in 32-bit words**, excluding the control word.
* The on-disk file is `(size + 2)` 32-bit words.
* Data outside the declared size is not persisted.

The important part: **the API reserves a DDR3 region and persists it. It serializes nothing.**
There is no register-walking helper, no scan chain, no framework module. Confirmed by inspection —
grepping `sys/` for savestate hooks finds nothing. All capture and restore logic is ours to write.

### DDR3 collision check

DDRAM is already a contended resource in this core, so this needed checking rather than assuming:

* The HDMI rotator owns `0x24000000`, 3x8 MB (`rtl/video/screen_rotate_two.sv:59`).
* The ROM loader borrows the bus during download (`Psikyo.sv:854-868`).
* The two are muxed by a flat priority mux at `Psikyo.sv:960-966`, gated on `ldr_active`.

`0x3E000000` is clear of both. But savestates add a **third** master, and the two-way mux has to
become a real arbiter. `rtl/memory/ddram_arbiter.sv` already exists — written for the abandoned
DDR3 ROM path, currently unused — and is the obvious starting point.

## 2. MAME as the reference for "what is meaningful"

`psikyo.cpp`'s own save list is short, and that shortness is the useful signal:

```cpp
void psikyo_state::machine_start()
{
	save_item(NAME(m_tilemap_bank));
}

void s1945_state::machine_start()
{
	psikyo_state::machine_start();
	...
	save_item(NAME(m_s1945_mcu_direction));
	save_item(NAME(m_s1945_mcu_inlatch));
	save_item(NAME(m_s1945_mcu_latch1));
	save_item(NAME(m_s1945_mcu_latch2));
	save_item(NAME(m_s1945_mcu_latching));
	save_item(NAME(m_s1945_mcu_control));
	save_item(NAME(m_s1945_mcu_index));
	save_item(NAME(m_s1945_mcu_mode));
	save_item(NAME(m_s1945_mcu_bctrl));
	save_item(NAME(m_mcu_status));
}
```

That is the *entire* driver-level state of a Psikyo board. Everything else MAME saves arrives from
two other places: memory shares are registered automatically, and each device saves itself
(`m68000_base_device`, `z80_device`, `ym2610_device`, `ymf278b_device`).

That three-way split maps exactly onto this core's difficulty gradient:

| MAME mechanism | Our equivalent | Difficulty |
|---|---|---|
| `save_item` in the driver | named registers we already have | trivial |
| auto-registered memory shares | BRAM walks | easy, precedent exists |
| device `device_start` save lists | CPU and sound-chip internals | the actual work |

Two pleasant coincidences fall out of this. `m_tilemap_bank` is a named register in
`rtl/video/vreg_decode.sv`. And `rtl/cpu/s1945_mcu.sv:59-60` declares
`direction, inlatch, latch1, latch2, control, index, mode` and `latching` — because that FSM was
written directly from `s1945_mcu_*`, its state is a **1:1 match with MAME's save list**. Where our
implementation follows MAME's structure, MAME's save list is a ready-made checklist.

Where it does *not* help: MAME's device save lists describe *MAME's* models. `ymfm`'s YM2610 state
and `jt10`'s YM2610 state are different data structures for the same chip. MAME tells us which
chip facts are meaningful (envelope phase, step index, accumulator); it does not tell us where
jt10 keeps them.

## 3. Memory inventory

All figures read from the RTL, cross-checked against `docs/phase1_memory_map.md`.

| Region | RTL | Size | Note |
|---|---|---|---|
| Work RAM | `psikyo_core.sv:247` (16-bit addr) | 128 KB | `0xFE0000-0xFFFFFF`; dominates the payload |
| Vreg/scroll RAM L0 | `vreg_decode.sv:173` (13-bit addr) | 16 KB | |
| Vreg/scroll RAM L1 | `vreg_decode.sv:183` | 16 KB | |
| Palette | `psikyo_core.sv:267` (12-bit addr) | 8 KB | |
| Tilemap VRAM L0 | `psikyo_core.sv:337` | 8 KB | |
| Tilemap VRAM L1 | `psikyo_core.sv:687` | 8 KB | |
| Sprite RAM (live) | `spriteram_dbuf.sv:77` | 8 KB | |
| Sprite RAM (snapshot) | `spriteram_dbuf.sv:92` | 8 KB | the hardware's frame buffer; must be saved |
| Z80 sound RAM | `sound_cpu.sv:201` | 2 KB | |
| Palette snapshot | `psikyo_core.sv:296` (9-bit addr) | 1 KB | regenerated at `frame_start`; skippable |
| s1945 MCU table | `s1945_mcu.sv:66` | 256 B | from the `.mra`, read-only after download; skip |

**Total ~200 KB.** A 256 KB slot (`SS3E000000:40000;`) covers it with room for the register state
and future growth; four slots is 1 MB of DDR3.

The reason that number is small: **SDRAM is read-only at runtime.** It holds nothing but ROM,
written only during `ioctl_download`. There is no writable SDRAM state to capture, which is what
keeps this a 200 KB problem instead of a tens-of-megabytes one.

## 4. Precedent already in this tree

The mechanically awkward part of a memory walk — quiescing the machine, borrowing a BRAM port
without adding a third port, streaming bytes out and back — is already built and shipping in this
core. `rtl/hiscore.v` pauses the CPU and reads and writes work RAM through the CPU's *own* port
(`psikyo_core.sv:224-260`), with the read byte registered next to the RAM specifically to keep it
off the critical path (that comment records it was worth ~300 failing endpoints otherwise).

A savestate engine is the same pattern generalised: every RAM instead of one, DDR3 instead of the
ioctl stream. That downgrades this from a novel design to a known one, and the pause/borrow
sequencing — the part most likely to produce a subtly corrupt state — is already proven on
hardware.

## 5. The CPUs

### Z80 sound CPU — solved upstream, at no cost

`rtl/cpu/t80/T80.vhd:124-127` already carries both halves:

```vhdl
REG    : out std_logic_vector(211 downto 0); -- IFF2, IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A
DIRSet : in  std_logic := '0';
DIR    : in  std_logic_vector(211 downto 0) := (others => '0')
```

Complete architectural state out, complete restore in. Two caveats, both small:

* `sound_cpu.sv:178` instantiates **`T80se`**, and `T80se.vhd` does not plumb `REG`/`DIR` through
  (checked — the only match in that file is the word "DIRECT" in the licence text). Adding two
  ports and passing them to the inner `T80` is a four-line change to a vendored file.
* `REG`/`DIR` is *architectural* state only — no M-cycle or T-state. Capture and restore therefore
  have to happen at an instruction boundary: suspend at M1, and `DIRSet` restarts execution at a
  fetch. This is how the console cores use it; it is a sequencing requirement, not a limitation.

### 68EC020 main CPU — no state port; use the bus instead of taps

TG68K.C has no equivalent. Its architectural state is the 16x32 register file at
`TG68KdotC_Kernel.vhd:185-186` plus PC, SR, USP/ISP, VBR, CACR and the prefetch queue, distributed
through a 4139-line kernel.

**Option (a): fork the kernel and add taps.** Rejected as the first choice. It is 4139 lines of
dense microcoded VHDL this project did not write and has no unit testbench for, and the part that
would actually need tapping for exactness — the microsequencer and prefetch state — is the part
least amenable to it.

**Option (b): make the CPU dump itself. Recommended.** Halt at an instruction boundary, then
substitute the instruction stream inside `rtl/cpu/maincpu.sv` — which already owns address decode
and DTACK — so the CPU executes a short stub that writes its own registers out:

* `MOVEM.L D0-D7/A0-A7,(An)` for the register file,
* `MOVEC` for VBR/CACR/SFC/DFC,
* an exception frame for PC and SR (forcing an exception is also what guarantees the instruction
  boundary in the first place).

Restore is the mirror, ending in `RTE`. The stub's writes go to a scratch region decoded *only* in
savestate mode, so game RAM is untouched by the mechanism. **Zero modification to the vendored
core** — every new line lives in our own wrapper.

Ordering matters and is easy to get wrong: the exception frame perturbs the game's stack, so the
sequence must be *snapshot RAM first, then run the stub*. On restore, writing RAM back undoes the
perturbation before the CPU resumes.

**The risk that decides this approach:** TG68K.C's 68020-mode coverage of `MOVEC` and of the `RTE`
stack frame formats. TG68K.C is known to be rough in 68EC020 mode, and this core has never
exercised either instruction. That is a ModelSim question, answerable in `sim/maincpu_tb/` in
isolation, and it must be answered *before* any other savestate work starts.

### s1945 PIC protection FSM

Ten registers (`s1945_mcu.sv:59-60`), matching MAME's `save_item` list exactly. `table_mem[0:255]`
comes from the `.mra` and never changes after download — skip it.

## 6. The sound chips — where the tier is decided

### jt10 (YM2610): the blocker

jt12 does not keep its per-slot state in a register file. It **circulates it through shift
registers** — `jt12_sh`, `jt12_sh_rst`, `jt12_sh24` — so that one physical operator pipeline
serves all slots. Instances found:

| Module | Shift register | Bits |
|---|---|---|
| `jt12_eg.v:163-194` | envelope counter, EG level (10b), EG state (3b), SSG invert, key-on | ~350 |
| `jt12_pg.v:96-104` | phase accumulators (20b x 4*num_ch) + pad | ~540 |
| `jt12_op.v:86-173` | operator feedback buffers (14b x 3) + phase modulation | ~310 |
| `jt12_csr.v:47` | per-channel register set, 12 stages | ~500 |
| `jt12_kon.v:91-141` | key-on per channel | ~30 |

Order 1.5 kbit for the FM section, plus ADPCM-A's six channel accumulators, step indices and
addresses, ADPCM-B, the SSG (jt49), the timers, and the `jt12_mmr` register file. **Under a
kilobyte in total** — the problem is not size, it is that none of it is addressable and there is
no state port anywhere in the core.

One structural fact is worth recording for whoever attempts Tier 2, because it makes the job
mechanical rather than clever: **every one of those shift registers is an instance of one of three
modules.** Adding a serial state-in/state-out to `jt12_sh`, `jt12_sh_rst` and `jt12_sh24` covers
the entire FM section by editing three files; the remaining work is plumbing ports up the
hierarchy. And the *dump* half does not even need that — a circulating shift register returns to
its original contents after `stages` shifts, so clocking it `stages` times with the feedback
intact and sampling the output is non-destructive. Only the restore half needs the input mux.

Even so, this is a fork of a vendored, battle-tested core to add a cross-cutting feature — on the
same core whose ADPCM path this project has just spent weeks getting right. That is the argument
for not doing it now.

### Tier 1: restore the register file, not the pipeline

Save `jt12_mmr`'s register map plus the ADPCM channel addresses and timer state, and on load
replay it as a write sequence through the normal YM address/data bus — exactly what the game's own
sound driver does after a reset. Envelopes restart from key-on and phase is lost, so any note held
across the save point re-attacks.

What the player hears: a fraction of a second of wrong-sounding music at load, then correct audio.
For a savestate that is a reasonable trade. For rewind or netplay it would not be — those need
Tier 2.

### OPL4 (Strikers, Tengai): enumerable, exact

`rtl/sound/opl4/opl4_pcm.sv:122-131` is nine explicit 24-entry arrays — `ch_baseaddr`, `ch_format`,
`ch_loop`, `ch_end`, `ch_nextpos`, `ch_lfo`, `ch_env`, `ch_tl`, `ch_key` — plus `opl4_regs`' RAM.
About 1 KB, all directly addressable, and we wrote it, so there is no vendoring argument to have.

Which means the SH403/SH404 games can have **bit-exact audio restore** while the YM2610 games are
on Tier 1. Worth stating in the README rather than letting it look like an inconsistency.

## 7. Video state

Nearly all of it regenerates within one frame — the sprite frame buffer, the palette snapshot, the
tilemap and sprite line engines' pipelines. Save the RAMs and the vregs, restore at a frame
boundary, and the renderer re-derives the rest on the next pass.

The exception, and it is the kind of thing that produces one wrong frame that nobody can explain
later: the **double-buffer phase** must be saved — `spriteram_dbuf.sv`'s live/snapshot selection
and the exported `ctrl_shadow[0]` that gates `sp_present`. Restore the wrong bank and the first
frame after load shows the previous frame's sprites. Aligning restore to `frame_start` is the
natural place to handle this.

## 8. Proposed phasing

| | Work | Gate |
|---|---|---|
| 3.0 | **Spike:** `MOVEC` and `RTE` frame-format coverage in TG68K 68020 mode, in `sim/maincpu_tb/` | Confirms or kills option (b). **Nothing else starts until this answers.** |
| 3.1 | DDRAM three-way arbiter; `SS` in `CONF_STR`; control word, slot select, OSD entries | |
| 3.2 | Memory walk to DDR3 and back, generalising `hiscore.v`'s pause/borrow pattern | |
| 3.3 | CPUs: `REG`/`DIR` through `T80se`; 68020 self-dump stub; s1945 FSM registers | |
| 3.4 | Audio Tier 1: OPL4 exact; YM2610 register-file replay | |
| 3.5 | *Deferred:* jt10 shift-register state chain for exact FM (Tier 2) | Only if Tier 1 proves insufficient in practice |

**Exit criteria:** save mid-game, reset the core, load, and continue with score, lives, and enemy
positions intact, on all five games. Driver-level fields (`tilemap_bank`, the MCU registers) A/B
against a MAME savestate of the same moment.

## 9. Risks, stated honestly

* **TG68K `MOVEC`/`RTE` coverage.** The recommended CPU approach hinges entirely on it, and
  TG68K.C is known to be rough in 68EC020 mode. This is why 3.0 is a gate and not a task.
* **Timing.** This design currently closes on roughly one fitter seed in eleven, with
  `sprite_line_engine` as the structural ceiling. A savestate engine adds a wide mux on every BRAM
  port and a third DDRAM master. Expect it to make the seed lottery worse before anything makes it
  better, and budget a timing pass as part of the work rather than as a surprise at the end.
* **Four slots.** A firmware limit, not negotiable.
* **Tier 1 audio is audibly imperfect at the instant of load.** Document it in the README, or it
  will be reported as a bug — reasonably.
* **Savestates are a correctness amplifier.** Any state we forget to save is invisible until a
  player loads a state and something is subtly wrong ten seconds later. The mitigation is MAME's
  own save lists as the checklist (§2), plus a deliberate save/restore/compare test in simulation
  rather than only by playing.
