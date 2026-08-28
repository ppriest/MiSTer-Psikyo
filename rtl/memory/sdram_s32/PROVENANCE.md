# `sdram_s32.sv` — provenance and modifications

**Upstream**: `rtl/mem/sdram.sv` from [meathax/s32](https://github.com/meathax/s32)
(Sega System 32 for MiSTer, GPL-3.0), cloned at commit
`3bce67e004608c73cbc257a51f05ccf3db67bbf0` (2026-08-28). Kept verbatim
alongside as `sdram_s32_upstream_reference.sv` for diffing.

Licence: GPL-3.0, same as this project already is via jt10.

## Why this replaces `rtl/memory/sdram/sdram.sv`

Our controller (Sorgelig's `sdram.v`, burst-4 extended) spends 10 cycles per
64-bit granule and only 4 of them move data; the other 6 are ACTIVATE + tRCD +
CAS paid on every transaction. Measured budget put the bus near 90%
utilisation, with the sprite engine alone at ~61%, which is the load-dependent
slowdown.

System 32 is a far heavier core -- more sprites, deeper colour -- and keeps up
on the same single SDRAM chip. What it does differently is NOT bank
interleaving or open-row caching for reads (its reads auto-precharge exactly
like ours). It is:

* **Burst width matched per consumer.** Sprites fetch 8 words (128 bit), tiles
  4 words. The ~6-cycle fixed overhead is amortised over twice the data, which
  lands on our single biggest consumer.
* **Latched request mailboxes**, so arbitration can delay a port long after the
  producer has moved on.
* **Bounded tile-deadline priority** with round-robin only for background
  traffic, because a tile fetch that waits behind a full rotation makes the
  renderer miss its scanline. We have `fetch_overrun` for exactly that failure
  and flat round-robin causing it.

## Modifications

1. `module sdram` -> `module sdram_s32`, to avoid colliding with the existing
   `rtl/memory/sdram/sdram.sv` while both are in the tree.
2. Refresh divider 700 -> 620. Upstream runs at 96.6 MHz where 8192 rows / 64 ms
   is every ~755 cycles; at our 85.909 MHz it is ~671, so 620 preserves the
   same ~93% margin.
3. Header comment: clk_ram (96.6 MHz) -> clk_sys (85.909 MHz).

## Deliberately NOT adopted (yet)

Upstream runs SDRAM in its own `clk_ram` domain at 96.634615 MHz with
`clk_sys = clk_ram/2`, which is why its ack is stretched to 2 cycles. Our
`clk_sys` is derived from the pixel clock (945/11 MHz) and cannot simply be
doubled, so stage 1 runs this controller single-domain at 85.909 MHz -- no CDC,
no clocking rework, and the burst/arbitration wins are independent of clock
rate. Raising the RAM clock is a separate stage.

## Request contract difference

Upstream is edge-triggered: one transaction per `req` RISING EDGE, and a held
`req` is serviced exactly ONCE. Our requesters hold `req` until valid and then
drop it, which produces a fresh rising edge per transaction and is compatible
-- but any requester that holds `req` through an ack expecting re-service will
hang. Check each one when wiring.

4. `ack_stretch` 2 cycles -> 1. Upstream holds ack for two cycles because its
   requesters live in a `clk_sys` domain running at `clk_ram/2`, so a 1-cycle
   ack could be missed. Stage 1 runs single-domain, where a 2-cycle ack instead
   makes `valid` twice as wide as every one of our consumers expects (they all
   assume the 1-cycle synchronous read our previous controller gave). Revert
   this if the separate RAM clock domain is ever adopted.

## Granule word order -- VERIFY IN SIMULATION

`p1_dout = {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}` puts the FIRST
word fetched in the LOW bits. Our previous controller appears to do the same,
which would keep `gfxrom_byte_reorder` valid unchanged -- but that is inferred
from reading, not measured, and getting it wrong scrambles every tile and
sprite. Confirm against `s32_sdr_chip_model.sv` in `sim/port2_sdram_tb/`
before building.
