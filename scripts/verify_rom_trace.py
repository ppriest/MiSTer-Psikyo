#!/usr/bin/env python3
"""Check a hardware ROM-read trace against the real ROM, and solve for the interleave.

WHY
---
`.mra` interleave maps are easy to get wrong and hard to verify. Every map for
this core was originally derived by reasoning about byte order, every derivation
was wrong, and the working one was eventually found by copying the idiom from a
shipped core (`Bucky O'Hare.mra`) and trying it. "It boots" is weak evidence: a
wrong map can still boot far enough to look plausible.

This closes that loop properly. Given a decoded on-hardware trace of CPU ROM
reads (address + data) and the original ROM zip, it brute-forces the small space
of plausible interleaves and reports which one reproduces the observed data
*exactly*. A 128/128 match against real silicon is proof; anything less is not.

Run on the maincpu trace this reported 128/128 for "even word <- 4-u127.bin,
big-endian within part", confirming the shipped map:

    <interleave output="32">
        <part name="4-u127.bin" map="0021"/>
        <part name="5-u126.bin" map="2100"/>
    </interleave>

USAGE
-----
    python scripts/decode_debug_screenshot.py cap.png --mode scanline \
        --split 8:16 --labels a,data > trace.txt
    python scripts/verify_rom_trace.py trace.txt roms/samuraia.zip \
        --parts 4-u127.bin 5-u126.bin

`--lines A:B` selects which decoded scanlines to use, for captures that put
different signals in different bands of the screen (default: 0:128).

NOTE the address in the trace is usually truncated (only the low bits fit in a
24-bit pixel), so this verifies *content*, not *address reach*. A read path that
aliases high address bits will still match here. Capture the full address in a
second buffer to test that -- see rtl/psikyo_core.sv.
"""
import argparse
import re
import sys
import zipfile


def load_trace(path, lo, hi):
    """Parse decode_debug_screenshot.py --labels a,data output -> [(addr, data)]."""
    rows = []
    for line in open(path):
        m = re.match(r'\s*(\d+)\s+a=0x([0-9A-Fa-f]+)\S*\s+data=0x([0-9A-Fa-f]+)', line)
        if m:
            idx = int(m.group(1))
            if lo <= idx < hi:
                rows.append((int(m.group(2), 16), int(m.group(3), 16)))
    return rows


def make_reader(parts, even_part, big_endian):
    """Model a 2-part interleave: alternate words come from alternate parts."""
    odd_part = 1 - even_part

    def word(w):
        n = w >> 1
        p = parts[even_part] if (w % 2 == 0) else parts[odd_part]
        if 2 * n + 1 >= len(p):
            return None
        return (p[2 * n] << 8) | p[2 * n + 1] if big_endian else (p[2 * n + 1] << 8) | p[2 * n]

    return word


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('trace')
    ap.add_argument('romzip')
    ap.add_argument('--parts', nargs=2, required=True,
                    help='the two ROM filenames inside the zip, in MRA order')
    ap.add_argument('--lines', default='0:128',
                    help='scanline range of the trace to use (default 0:128)')
    args = ap.parse_args()

    lo, hi = (int(x) for x in args.lines.split(':'))
    trace = load_trace(args.trace, lo, hi)
    if not trace:
        sys.exit('no trace rows parsed from %s in line range %d:%d' % (args.trace, lo, hi))

    z = zipfile.ZipFile(args.romzip)
    names = {n.lower(): n for n in z.namelist()}
    try:
        blobs = [z.read(names[p.lower()]) for p in args.parts]
    except KeyError as e:
        sys.exit('part not found in %s: %s\navailable: %s'
                 % (args.romzip, e, ', '.join(sorted(names.values()))))

    print('trace: %d reads from %s (lines %d:%d)' % (len(trace), args.trace, lo, hi))
    for p, b in zip(args.parts, blobs):
        print('  part %-16s %d bytes' % (p, len(b)))
    print()

    best = None
    for even_part in (0, 1):
        for be in (True, False):
            word = make_reader(blobs, even_part, be)
            hits = sum(1 for a, d in trace if word(a) == d)
            label = 'even word <- %-14s %s within part' % (
                args.parts[even_part], 'big-endian   ' if be else 'little-endian')
            print('  %s :  %3d/%d' % (label, hits, len(trace)))
            if best is None or hits > best[0]:
                best = (hits, even_part, be, label)

    hits, even_part, be, label = best
    print()
    if hits == len(trace):
        print('EXACT MATCH -- interleave confirmed against hardware:')
        print('  %s' % label)
        word = make_reader(blobs, even_part, be)

        # Deliberately print BOTH readings rather than asserting one is "the" SP/PC.
        # This model is fitted to the *captured* words; whether the byte swap sits
        # in the capture packing or in the CPU's own byte lanes is not something
        # this script can see. Printing a single confident-looking SP that is
        # actually the un-swapped form would be exactly the sort of plausible-but-
        # wrong readout that has misled this project before.
        def sw(v):
            return ((v & 0xFF) << 8) | (v >> 8)

        print('  reset vector, as captured : SP=%04X%04X  PC=%04X%04X'
              % (word(0), word(1), word(2), word(3)))
        print('  reset vector, byte-swapped: SP=%04X%04X  PC=%04X%04X'
              % (sw(word(0)), sw(word(1)), sw(word(2)), sw(word(3))))
        print('  (for samuraia the correct pair is SP=FFFF8000 PC=00000400 --'
              ' whichever row shows that identifies where the swap lives)')
        return 0

    print('NO exact match. Best was %d/%d (%s).' % (hits, len(trace), label))
    print('Either the map is wrong, or the read path is corrupting data.')
    word = make_reader(blobs, even_part, be)
    print('\nfirst mismatches (addr / observed / expected):')
    shown = 0
    for a, d in trace:
        exp = word(a)
        if exp != d:
            print('  %05X   %04X   %04X' % (a, d, exp if exp is not None else 0))
            shown += 1
            if shown >= 16:
                break
    return 1


if __name__ == '__main__':
    sys.exit(main())
