# debug/ — reference traces and captures

Ground-truth references for core bring-up. Not build inputs; nothing here is
compiled or simulated. Kept in git so a future session can diff against known-good
behaviour instead of re-deriving it from hardware symptoms.

## `mame_samuraia_boot_trace.txt.gz`

A MAME CPU trace of `samuraia` from reset through initialisation — 480,931 lines,
gzipped (12 MB raw → 1.4 MB). Produced by the project owner from MAME's debugger;
regenerate with MAME's `trace` command if a longer or different window is needed.

```bash
zcat debug/mame_samuraia_boot_trace.txt.gz | head -40          # entry sequence
zcat debug/mame_samuraia_boot_trace.txt.gz | grep -n '^000404' # find a specific PC
```

**Why it matters.** This is the oracle for what the 68EC020 *should* do, and it
settles in seconds what otherwise costs 12-minute build/deploy/screenshot round-trips
to infer. Facts it establishes immediately:

- Execution enters at `000404: lea $ffff7000.l, A0`, i.e. the reset vector's PC is
  `0x00000400`. The initial SP from the vector barely matters — the game sets its own
  almost immediately (`00041A: lea $ffff7fe0.l, A7`), after `movec D0, CACR` enables
  the 68020 instruction cache.
- The very first thing it does is `jsr $8f8`, a checksum loop over `$5e614` summing
  longs — so a corrupt program ROM is detected by the game itself, early.
- **Valid PC ranges are only `0x000xxx` and `0x06Cxxx`–`0x079xxx`** (by line count:
  `070` 253k, `000` 38k, `072` 27k, `079` 24k, `071` 22k, `076` 19k, `06C` 15k,
  `06F` 12k). Any PC outside those is garbage.

That last point is the useful test. When a hardware bus-address capture showed the core
jumping to `0xCD1280` after correctly fetching the reset vector from addresses
`0,2,4,6`, comparing against this range list proved instantly that the *addresses* were
right and the *data* coming back from SDRAM was wrong — which is a completely different
bug from the one being chased at the time.

## Capturing the equivalent from real hardware

There is no JTAG on this setup yet, so hardware traces come from the VGA debug-tap
technique documented in `docs/LESSONS_LEARNED.md`: drive internal state onto
`VGA_R/G/B`, screenshot via `scripts/mister_hw_test.py`, and decode the pixels. A
BRAM ring indexed by `vcnt` gives 224 consecutive bus cycles in a single screenshot.
Always remove that instrumentation before a release build.
