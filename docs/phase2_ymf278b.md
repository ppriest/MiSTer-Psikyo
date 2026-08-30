# YMF278B (OPL4) sound core

Plan and status for the from-scratch YMF278B implementation that replaces the jt10
stand-in on SH403/SH404 (Strikers 1945 protected sets, Tengai). Approved scope
(2026-08-30): **full chip -- FM synthesis + 24-channel PCM wavetable** -- built in two
milestones, PCM first.

## Why, and why PCM first

Hardware probing (docs/phase2_sh404.md "SH404 audio") confirmed the Z80 sound driver
runs perfectly against the chip window -- it is the chip that is missing: no FPGA
YMF278B exists anywhere (jtopl covers OPL2/OPL3 only; jt262/OPL3 is "Not yet" in that
project). The games' `ymf` ROM regions are 2-4MB of wavetable sample data; the OPL4's
PCM engine, not FM, carries essentially all of the score. So milestone 1 is everything
the driver interacts with plus the PCM engine; FM synthesis is milestone 2.

The accuracy reference is MAME's own ymfm library (mame/3rdparty/ymfm --
`ymfm_opl.h/.cpp` `ymf278b` class and `ymfm_pcm.h/.cpp` `pcm_engine`), the exact code
MAME uses for these games. Every table and formula below is taken from it, not from
the datasheet alone.

## Milestone 1 (this phase): bus + timers + PCM

New RTL under `rtl/sound/opl4/`:

### opl4_regs.sv -- bus, status, timers, register file

- 6-port bus protocol (Z80 I/O 0x08-0x0D): FM addr-lo/data, FM addr-hi/data,
  PCM addr/data. 10-bit internal address (bit9 = PCM space, bit8 = FM high bank,
  high bank masked in non-NEW mode except reg 0x105, like YMF262).
- Status: IRQ/timerA/timerB flags, BUSY (56 chip clocks after FM writes, 88 after
  PCM writes), LD (13 samples after a wavetable select). First read after reset or
  NEW2 0->1 returns the chip ID (NEW2 ? 02 : NEW ? 00 : 06). BUSY/LD masked outside
  OPL4 mode -- all straight from `ymf278b::read_status()`.
- **Timers with IRQ**: timer A = (1024 - 4*regA), timer B = 16*(256 - regB), both in
  FM-sample units (chip/684 = 49.515kHz); RST/mask semantics from reg 04. This is the
  Z80 driver's sequencer heartbeat -- it matters as much as the audio path.
- NEW/NEW2 flags; PCM register writes are gated on NEW2 exactly like the reference.
- 256-byte PCM register file (flops -- it needs several asynchronous read ports).
- External-memory window (PCM regs 02-06): read side implemented with a prefetch
  buffer (a Z80 I/O read cannot stall), post-increment on data-port access; the write
  side is a no-op because the wave ROM is SDRAM-resident and read-only (the real
  board has no wave SRAM either).

### opl4_pcm.sv -- the 24-channel wavetable engine

One output sample per chip/768 tick (44.1kHz). Each sample walks the channels
sequentially; a slot reads the channel's registers through the regfile port, then:

- key pending -> attack (position reset; rate-63 instant-full) / release;
- pitch step `((0x400|fnum) << (octave+7)) >> 2` as a .16 increment, vibrato from a
  per-channel x.18 LFO with the reference's step/depth tables;
- envelope generator: the shared OPN increment table, rates `raw*4 + rate correction`
  (correction `(octave+RC)*2 + fnum[9]`, RC=15 disables), sustain-level extension
  (15->31), damp override (decay 48 to -12dB then max), pseudo-reverb transition at
  -18dB with rate 5, attack `att += ~att*inc >> 4`;
- total-level interpolation (+19/-38 per sample) or direct;
- sample fetch from the wave ROM via SDRAM: formats 8-bit, 12-bit (3 bytes / 2
  samples), 16-bit; loop wrap `pos += loop - end` (end stored negated in the ROM);
- output: attenuation = env + AM + TL + pan, exponent via the 256-entry power table
  (`pow[att[7:0]] >> att[12:8]`), `vol*sample >> 15` accumulated left/right.
- wavetable loads (writes to 0x08-0x1F): 12-byte header fetch from the ROM
  (banked above wave 384 via reg 02 bits 4:2); bytes 7-11 write the channel's
  LFO/AR-DR/SL-SR/RC-RR/AM registers, envelope forced silent -- `load_wavetable()`
  verbatim.

Quiet released channels early-out after one register read, keeping the walk well
inside the ~1948-clock sample budget; a pathological overrun stretches the sample
rather than corrupting the walk.

### opl4.sv -- top

Chip-clock enable (33.8688MHz from clk_sys by Bresenham, /768 sample tick and /684
FM tick derived from it so timers and audio stay phase-locked), the SDRAM read
arbitration between the PCM engine and the memory window, and the output mix: the
DO2 mix-control attenuators (regs F8/F9, `s_mix_scale`) applied to FM (zero in
milestone 1) and PCM. Both PCM output pairs (DO1 and DO2) are summed -- this board
has one DAC on the mixed output; summing avoids muting anything a driver routes to
the unmixed pair.

### Integration

- `sound_cpu.sv`: the SH404 chip window (0x08-0x0D) routes all six ports to the
  OPL4 (3-bit offset); jt10 keeps the window on the YM2610 boards.
- `psikyo_top.sv`: OPL4 instantiated alongside jt10; `board_sh404` selects whose
  output drives snd_left/right and whose irq_n reaches the Z80.
- SDRAM: the OPL4 reuses the ADPCM-A client (idle on SH404 boards -- jt10 makes no
  fetches there), widened to a 22-bit address covering the 4MB sample region the
  2026-08-30 re-layout reserved at 0x0E40000. The `.mra` files already load the
  `ymf` ROMs there.

### Verification

- `sim/opl4_tb/`: protocol tests (ID/status/busy/NEW2 gating, timer periods and
  IRQ against computed FM-sample counts), then PCM behavior against a behavioral
  wave ROM: header fetch addressing (incl. bank), 8/12/16-bit sample addressing and
  nibble packing, pitch stepping rate, loop wrap, keyon->attack->audible /
  keyoff->release->silent, panning and TL attenuation directions.
- Hardware: deploy and listen (s1945/tengai), with the sound-chain ISSP probe for
  liveness. Golden-trace comparison against ymfm sample output is a possible later
  tightening.

## Milestone 2 (later): FM synthesis

OPL3-compatible FM (18 2-op channels, 4-op pairing, 8 waveforms) behind the same
register file, replacing the milestone-1 "timers only" FM stub. The ymfm
`fm_engine_base<opl4_registers>` remains the reference; jtopl's architecture is a
useful structural guide even though its OPL3 top is unfinished. The FM/PCM sample-
rate offset (FM at chip/684 vs output at chip/768) needs the reference's 192/171
resampling trick.

## Known simplifications (deliberate, documented)

- FM audio absent in milestone 1 (timers/status/IRQ fully present).
- Memory-window writes are dropped (read-only SDRAM wave ROM; no wave SRAM on this
  board).
- Key-on takes effect at the channel's next sample slot (<= one 44.1kHz sample of
  latency) -- matches the reference's deferred prepare within a sample.
- DO0 (FM-only pins) unconnected; DO1 summed into the mixed output (see opl4.sv).

## FM synthesis: measured as unnecessary (2026-08-30)

Milestone 2 (an FM synthesis engine) was dropped after measuring what the
games actually ask the chip to do, rather than assuming the FM half must be
needed because the hardware has one.

Instrumentation: `opl4.sv` exports three pulses -- any write to an FM register,
an FM key-on (registers B0-B8, bit 5), and a PCM key-on -- using ymfm's own
FM/PCM selector, bit 9 of the register address (`ymf278b::write_data` vs
`write_data_pcm`). They feed ISSP instance `F`, decoded by
`scripts/read_issp.tcl`.

Result on Strikers 1945 (Korea), `board_sh404 = 1`, over an attract-mode run:

| counter | early sample | later sample |
|---|---|---|
| FM register writes | 12,265 | 34,655 |
| FM key-ons | 0 | **0** |
| PCM key-ons | 714 | 7,799 |

PCM key-ons rose eleven-fold while FM key-ons stayed at exactly zero. The
driver programs FM state continuously and never keys a channel on, so no FM
voice can ever be audible and an FM engine would change nothing.

What this does NOT license: the FM register writes still have to be accepted,
and the chip ID, status and timer behaviour still have to be correct, or the
Z80 sound driver can stall waiting on them. That part is implemented and is
why the games run.

Still to confirm on Tengai, which runs a different sound program.
