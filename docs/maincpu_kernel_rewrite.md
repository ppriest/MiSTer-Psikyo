# maincpu.sv rewrite: drive TG68KdotC_Kernel directly at 16 MHz

Status: **planned, not started.** Written 2026-08-23 so the plan survives a context reset.

## Why

`rtl/cpu/maincpu.sv` currently instantiates `TG68K` (the `TG68K.vhd` wrapper). That wrapper is an
**async-68000-bus adapter**, not the CPU: it emulates real 68000 bus phases with AS/UDS/LDS/DTACK
and therefore contains `falling_edge` registers (`as_e`, `rw_e`, `uds_e`, `lds_e`, `clkena_e`,
`data_akt_e`, `cpuIPL`, `waitm`, `E`). It assumes `CLK` **is** the CPU clock.

The 68EC020 must run at 16 MHz (MAME `psikyo.cpp` `sngkace()`, "verified on pcb") while `clk_sys`
is 85.909091 MHz, and TG68K's measured Fmax on this device is **48.74 MHz** — so it cannot be
clocked at `clk_sys` regardless of accuracy. Rate-limiting the wrapper was attempted and produced
a chain of failures (see `LESSONS_LEARNED.md`, "TG68K.C"): dual clock enables for the two edges,
an ordering bug, and then a `set_multicycle_path` that silently granted half-cycle paths up to
~46 ns. It never booted on hardware.

`TG68KdotC_Kernel` is **entirely rising-edge** (verified: zero `falling_edge` occurrences) and
exposes `clkena_in` for exactly this purpose. Established cores instantiate the kernel directly.

## Reference implementation

`mist-devel/plus_too`'s `tg68k.v` (https://github.com/mist-devel/plus_too/blob/master/tg68k.v):

```verilog
wire tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01);
```

Its own state machine owns DTACK and stalls the CPU purely by gating `clkena_in`. Nothing inside
the core is modified.

## Kernel interface (from `rtl/cpu/tg68k/TG68KdotC_Kernel.vhd`)

```
clk, nReset, clkena_in
data_in[15:0], IPL[2:0], IPL_autovector, berr, CPU[1:0]
addr_out[31:0], data_write[15:0], busstate[1:0], nWr, nUDS, nLDS
nResetOut, FC[2:0], skipFetch
```

`busstate` encoding — **confirm against the kernel source before relying on it**; `2'b01` is
known to mean "no memory access" (CPU may free-run).

Generics to keep identical to today's `TG68K` instantiation: `SR_Read=2`, `VBR_Stackframe=2`,
`extAddr_Mode=2`, `MUL_Mode=2`, `DIV_Mode=2`, `BitField=2`, `BarrelShifter=0`, `MUL_Hardware=1`,
with `CPU=2'b11` (68020) driven as a port.

## Plan

1. **Add a 16 MHz enable.** Bresenham 176/945 off `clk_sys` (exact; see `LESSONS_LEARNED.md`).
   Already written and working in the current `maincpu.sv` — keep that block verbatim.
2. **Instantiate `TG68KdotC_Kernel` directly**, replacing the `TG68K` instance. Drive
   `clkena_in = cpu_ce && <bus state machine ready>`.
3. **Write the bus state machine** against `busstate`/`nUDS`/`nLDS`/`nWr` instead of
   AS/UDS/LDS/DTACK. It owns the wait handshake for the req/valid ROM port and the fixed
   one-cycle BRAM regions, and stalls the CPU by deasserting `clkena_in`.
4. **Keep unchanged**: address decode (`addr24`, all `is_*` region selects), every BRAM port,
   input-port reads, the sound-latch write, and the vblank IRQ logic (already fixed — edge-set,
   acknowledge-priority).
5. **Delete**, as they exist only to support the wrapper:
   - `ext_clkena` / `ext_clkena_f` from `rtl/cpu/tg68k/TG68K.vhd`, restoring it to vendored state
     apart from the confirmed `ext_force_run`/`effective_reset` RESET/HALT fix
   - the CPU `set_multicycle_path` block in `Psikyo.sdc` (an all-posedge kernel gated by a real
     enable needs none)
   - `rom_data_l` / `rom_ready` / `rom_access_d` and the `access_started` write gating in
     `maincpu.sv` **if** the new state machine makes them redundant — re-derive, do not assume
6. **Verify** with `sim/maincpu_tb/tb_maincpu.sv` (both cases must pass) and then
   `sim/psikyo_top_tb/tb_psikyo_top_realrom.sv` (expect `FIRST WRITE: workram addr=c07e`).
7. **Then** hardware, and diff the fetch trace against `debug/mame_samuraia_boot_trace.txt.gz`
   (entry is `000404: lea $ffff7000.l,A0`, i.e. word address `0x202`).

## Known-good state to preserve

These are independently verified and must survive the rewrite:

- `sdram_reset = reset & ~ioctl_download` in `psikyo_top.sv` — without it the ROM download never
  reaches SDRAM at all (confirmed at the pins: `CMD_WRITE` 0x000 -> 0xE00)
- vblank IRQ: edge-triggered set, acknowledge takes priority
- `vreg_decode.sv` `KA302C_BANKING` — samuraia needs layer0=bank0, layer1=bank1
- `ext_force_run`/`effective_reset` in `TG68K.vhd` (the RESET/HALT synthesis fix)
- the maincpu `.mra` interleave: `<interleave output="16">` with `map="01"`/`map="10"` — verified
  on hardware to decode `SP=0xFFFF8000 PC=0x00000400`

## Still open, not part of this rewrite

- gfx `map="21"` for sprites/tiles is **unverified** — an offline decode of `u34.bin` proved a
  byte-swap is needed, but the `map` digit semantics have been misread once already, so the
  specific value is not trusted until real artwork renders
- ~600 `sprite_render_engine` paths fail timing at −3.0 ns (pre-existing, was masked by the far
  worse CPU paths)
