# tools/

Third-party build tools used during development, kept out of version control.

## vasm (m68k, Motorola syntax)

Used to assemble the test programs in `sim/tg68k_spike/*.s` for the TG68K.C
CPU spike, rather than hand-encoding 68k machine code (see
`rtl/cpu/tg68k/PROVENANCE.md` for why: two separate hand-encoding mistakes
early on each briefly looked like TG68K.C bugs before turning out to be
transcription errors on our part).

**Not vendored here** -- vasm's license
(http://sun.hasenbraten.de/vasm/index.php?view=main, "Legal" section) allows
redistributing the unmodified source archive for non-commercial use, but
doesn't clearly cover redistributing a self-compiled binary, and anything
else needs the author's written consent. Simplest to just not commit it.

Run `scripts/fetch_build_vasm.sh` (needs `curl`, `tar`, and a C99 compiler
as `$CC`, default `clang`) to fetch the official source and build
`tools/vasm/vasmm68k_mot.exe` locally. This directory is gitignored.
