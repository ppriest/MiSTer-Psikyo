# Phase 2: SH403/SH404 hardware (Strikers 1945 / Tengai)

Analysis of what SH403/SH404 support adds versus the Phase-1 core, read directly from
current MAME `psikyo.cpp` / `psikyo_v.cpp` (fetched 2026-08-30). Approved 2026-08-30.

Simplifications agreed for this phase:

- The LZ8420M is treated as a plain Z80 (T80), exactly as MAME treats it.
- The sound chip is substituted with the existing jt10 (YM2610) for now. The real chip
  on SH403/SH404 is a YMF278B (OPL4; YMF268-K on some PCBs) with OPL register/status
  semantics -- **not** the YM2610-compatible YMF286-K found on KA302C. Audio on the
  MCU-protected sets will be wrong/silent until an OPL4 core exists (README note).

## The free win: s1945n / s1945nj

"Strikers 1945 (unprotected)" runs on the **gunbird machine config** (`init_gunbird`,
Z80+YM2610, no MCU, KA302C vreg tile banking). Its only difference from btlkroad on
this core is the sound latch at **C00011 instead of C00013**, and its sound ROM
(`3-u71.bin`) is written for the YM2610 -- so it gets fully correct audio on the
existing hardware. Milestone 1: one mod-byte flag + two MRAs validates the whole game
family (sprites, tiles, DIPs) before any MCU work.

## Identical across all boards (no work)

68EC020 @16MHz, memory map for ROM/spriteram/palette/VRAM/vregs/workram, held IRQ4 on
vblank, video timing (PCB notes confirm 14.31818/2, 456x262, 320x224, 59.923Hz),
buffered spriteram, palette format, sprite LUT (0x40000, 16LE), gfx pixel format.

The sound CPU **program map and bank switching are byte-for-byte the gunbird scheme**:
fixed 0000-7FFF, RAM 8000-81FF, banked window 8200-FFFF, bank register =
`(io_port_0x00 write >> 4) & 3`, entries at ROM base+0x200. `sound_cpu.sv` needs no
banking changes. Z80 clock 16/2 = 8MHz per MAME (PCB notes claim 4MHz on the LZ8420M
pin; match MAME per standing rule).

## The security device (PIC16C57 simulation)

MAME never executes the PIC (`set_disable()`); it models it as ~9 bytes of state plus
a command decoder. Direct translation to `rtl/s1945_mcu.sv` -- a register file with a
command `case`, no FSM.

State (reset values from `machine_start`):

```
direction=0x00  inlatch=0xFF  latch1=0xFF  latch2=0xFF  latching=0x5
control=0xFF    index=0       mode=0       bctrl=0x00   mcu_status=0
```

Writes (byte addresses):

| byte | register |
|---|---|
| C00006 | inlatch (data) |
| C00007 | bctrl -- **also switches tile banks** (see below) |
| C00008 | control |
| C00009 | direction |
| C0000B | command |

Command decode on `{direction != 0, data}`:

- `0x11C`: `latching=5; index=inlatch`
- `0x013`: `latching=1; latch1=table[index]` -- only if a table is present. Tengai has
  **no table** and latch1 stays unchanged, which is NOT the same as a zero table.
- `0x113`: `mode=inlatch`; if mode==1 `{latching&=~1; latch2=0x55}` else
  `{latching&=~1; latching|=2}`; then `latching&=~4; latch1=inlatch`
- `0x010`/`0x110`: `latching|=4`

Reads:

- C00008 returns `latching | 0x08` (bit 3 stuck high).
- DSW word C00006 returns in bits 15:8:
  `control&0x10 ? (latching&4 ? 0xFF : latch1) : (latching&1 ? 0xFF : latch2)`
  and **the read consumes the data** (sets that latching bit). Bits 7:4 = `bctrl[7:4]`,
  bits 3:0 = the region DIP nibble.

Read side effects on the 16-bit TG68 bus: a 68020 long read of C00004 becomes two word
cycles. The consume must fire once, on the **word-C00006 read strobe only** -- firing
on the C00004 half would invalidate the latch before the half that carries it returns.
The `mcu_status` toggle fires once per word-C00002 read strobe.

## Bit polarity (past bugs lived here)

- **P1_P2 byte C00003 bit 2 = MCU status, ACTIVE_HIGH, raw**: toggles on every read
  (MAME's own "hack"; tengai's POST spins on it both directions). Must bypass the
  `~joystick` inversion applied to every neighboring bit.
- **P1_P2 bit 7 (z80 NMI status) is ACTIVE_HIGH** -- same as gunbird today; reuse.
- **The DSW vblank bit is GONE on SH404**: gunbird's active-low vblank at DSW bit 7 is
  replaced by `bctrl[7]` readback. Wiring vblank there corrupts the MCU handshake.
- **Not-ready reads return 0xFF**, not 0x00, in the data byte.
- Region nibble: World=0xF on s1945/tengai; on s1945a/tengaij 0xF=**Japan**, 0xE=World;
  ignored on s1945j/s1945k. `write_cfg.py` DIP_DEFAULTS for the new sets must come from
  each new MRA's `<switches default>` (the gunbird 0F lesson).

## The MCU tables

The three tables (44 meaningful bytes each, rest zero -- the index is 8-bit into a
zero-filled 256-byte array) differ in **five** positions:

| index | s1945 | s1945a | s1945j |
|---|---|---|---|
| 0x03 | AE | BE | B6 |
| 0x1E 0x1F | C5 1E | C7 2A | C5 92 |
| 0x26 0x27 | AC 5C | AD 4C | AC 64 |

s1945k uses the s1945 table; tengai/tengaij have no table at all. Decision: a 256-byte
RAM in the core, **whole table delivered by the MRA** in the mod-ROM payload; tengai
sets a "table absent" flag instead. No RTL tables to maintain, and old MRAs (1-byte
payload) leave the RAM zeroed harmlessly.

## Tile bank switching (SH404 video difference)

`bctrl` writes drive the banks directly: **layer0 bank = bctrl[5:4], layer1 =
bctrl[7:6]** -- full 2-bit, using the whole width of `vreg_decode.sv`'s existing 2-bit
`layer0_bank`/`layer1_bank` ports. Banking becomes a three-way mode: sngkace fixed
{0,1}; KA302C from layer-ctrl bit 10 (unchanged); SH404 from bctrl. Tengai's 4MB tile
ROM is why the banks are 2 bits.

## SDRAM re-layout

Tiles previously got 2MB (`TILES_BASE 0x0A40000` -> `ADPCMA_BASE 0x0C40000`); tengai
needs 4MB, and the OPL4 sample ROMs are another 4MB if loaded. New layout:

| region | base | size |
|---|---|---|
| MAINCPU   | 0x0000000 | 2MB |
| AUDIOCPU  | 0x0200000 | 256KB |
| SPRITES   | 0x0240000 | 8MB (s1945 uses exactly 8MB) |
| TILES     | 0x0A40000 | 4MB |
| ADPCMA/PCM| 0x0E40000 | 4MB (ADPCM-A + delta-T inside it for KA302C/SH201B; OPL4 wave later) |
| SPRITELUT | 0x1240000 | 256KB |

Total 18.5MB. Compatibility break: all 9 existing MRAs regenerated (offset padding);
rbf + mra must be updated as a pair.

## Sound IO map (SH403/SH404)

| io | function |
|---|---|
| 0x00 write | bank select, `(data>>4)&3` (same as gunbird) |
| 0x02-0x03 write | no-op (must be ignored, not trapped) |
| 0x08-0x0D | sound chip window (6 ports; jt10 on 0x08-0x0B for now, 0x0C/0x0D read 0) |
| 0x10 read | sound latch |
| 0x18 write | latch acknowledge (clears NMI) |

Risk: the Z80 program may spin on OPL timer flags (status bits 6:5) that jt10 never
sets. If boot-blocking, fallback is a ~50-line OPL timer/status shim (timers + IRQ,
no sound). Decide from a MAME sound-CPU trace of s1945 boot; also request a 68020
trace of the C00xxx MCU handshake as the testbench oracle.

## Mod byte

| bit | meaning | sets |
|---|---|---|
| 0 | board_gunbird (existing) | gunbird, btlkroad, s1945n/nj, s1945 x4, tengai x2 |
| 1 | needs_adpcma_swap (existing) | samuraia/sngkace |
| 2 | snd_latch_c00011 | s1945n/nj, s1945 x4, tengai x2 |
| 3 | board_sh404 (MCU + bctrl banking + s1945 sound IO) | s1945 x4, tengai x2 |
| 4 | mcu_table_absent | tengai x2 |

Mod payload bytes 4..47 = MCU table (44 bytes; unwritten bytes read 0).

Eight new MRAs: s1945, s1945a, s1945j, s1945k, s1945n, s1945nj, tengai, tengaij.
Tengai gotchas: sprites load u20, u22, u21 **in that order**; its sprite/tile regions
are plain `ROM_LOAD` (no word swap) unlike every other set, so its MRA interleave must
be built from the ROM_START, not copied; tengai is ROT0 like btlkroad.

## Work order

1. SDRAM re-layout + regenerate the 9 existing MRAs; hardware-verify no regression.
2. s1945n/s1945nj (mod bit 2 + MRAs) -- full game, correct audio, on today's hardware.
3. MCU module + table-via-MRA + input polarity + bctrl banking + SH404 sound IO,
   testbench against a MAME trace; s1945/a/j/k MRAs.
4. Tengai: table-absent flag, 4MB tiles, plain byte order, ROT0.
