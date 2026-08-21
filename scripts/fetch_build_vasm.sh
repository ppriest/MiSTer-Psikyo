#!/usr/bin/env bash
# Fetches and builds vasm (m68k, Motorola syntax) from the official source,
# for generating/verifying test programs used by sim/tg68k_spike/.
#
# vasm is NOT vendored in this repo -- its license (see
# http://sun.hasenbraten.de/vasm/index.php?view=main, "Legal" section)
# permits redistributing the unmodified archive for non-commercial use, but
# a self-compiled binary isn't clearly covered by that and modified/partial
# redistribution needs the author's written consent. Building it locally on
# demand avoids the question entirely. Output goes to tools/vasm/, which is
# gitignored.
#
# Requires: curl, tar, and a C99 compiler on PATH as $CC (defaults to clang).

set -euo pipefail

CC="${CC:-clang}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
OUT_DIR="$REPO_ROOT/tools/vasm"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Fetching vasm source..."
curl -sf -o "$BUILD_DIR/vasm.tar.gz" "http://sun.hasenbraten.de/vasm/release/vasm.tar.gz"
tar xzf "$BUILD_DIR/vasm.tar.gz" -C "$BUILD_DIR"

cd "$BUILD_DIR/vasm"
echo "Building vasmm68k_mot with $CC (no -DUNIX: uses the native _WIN32 path in osdep.c)..."
"$CC" -std=c99 -DOUTBIN -DOUTELF -DOUTHUNK -DOUTAOUT -DOUTTOS -DOUTSREC -DOUTIHEX \
  -I. -Icpus/m68k -Isyntax/mot \
  vasm.c atom.c expr.c symtab.c symbol.c error.c parse.c reloc.c hugeint.c \
  cond.c listing.c source.c supp.c dwarf.c osdep.c \
  cpus/m68k/cpu.c syntax/mot/syntax.c \
  output_test.c output_elf.c output_bin.c output_vobj.c output_hunk.c output_aout.c \
  output_tos.c output_xfile.c output_srec.c output_cdef.c output_ihex.c output_o65.c \
  output_gst.c output_woz.c output_pap.c output_hans.c output_coff.c output_aof.c \
  -o vasmm68k_mot.exe

mkdir -p "$OUT_DIR"
cp vasmm68k_mot.exe "$OUT_DIR/"
echo "Done: $OUT_DIR/vasmm68k_mot.exe"
