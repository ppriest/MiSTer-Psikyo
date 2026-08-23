#!/usr/bin/env python3
"""Decode a VGA debug-tap screenshot back into the values the RTL was driving.

The bring-up technique this supports is documented in docs/LESSONS_LEARNED.md:
with no JTAG available, internal state is driven straight onto VGA_R/G/B, a
screenshot is pulled with scripts/mister_hw_test.py, and the pixels are read
back here. Each pixel carries 24 bits (R<<16 | G<<8 | B).

There is deliberately no PIL/numpy dependency -- neither is installed in this
environment -- so the PNG is decoded by hand (zlib + the five filter types).
Only the 8-bit truecolour PNGs MiSTer's screenshot API produces are supported.

Modes, matching the three tap shapes used so far:

  counters   Histogram of distinct colours. For taps that drive a few live
             counters/flags, where the whole screen is one or a handful of
             solid colours.
               e.g. R=ROM fetches, G=IACK count, B=palette writes

  scanline   One value per scanline, read from mid-line. For a BRAM trace
             indexed by vcnt, where each scanline shows one captured entry.
             This is the useful one for bus traces.

  raster     Every pixel in raster order, run-length compressed. For a tap
             driving a live value that changes faster than the frame, giving
             ~71680 consecutive samples in one screenshot.

Examples:
  python scripts/decode_debug_screenshot.py shot.png --mode counters
  python scripts/decode_debug_screenshot.py shot.png --mode scanline --limit 40
  python scripts/decode_debug_screenshot.py shot.png --mode scanline \
      --split 8:16 --labels addr_lo,data
  python scripts/decode_debug_screenshot.py shot.png --mode raster -o trace.txt
"""

import argparse
import struct
import sys
import zlib


def read_png_rows(path):
    """Return (width, height, rows) with rows as bytes objects of RGB triples."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, width, height, depth, ctype = 8, b"", 0, 0, 0, 0
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        tag = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        if tag == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", chunk[:10])
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break
        pos += 12 + length
    if depth != 8 or ctype != 2:
        raise SystemExit(
            f"{path}: only 8-bit truecolour PNG supported (got depth={depth} type={ctype})"
        )

    raw = zlib.decompress(idat)
    bpp, stride = 3, width * 3
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        if ftype:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                if ftype == 1:
                    line[x] = (line[x] + a) & 0xFF
                elif ftype == 2:
                    line[x] = (line[x] + b) & 0xFF
                elif ftype == 3:
                    line[x] = (line[x] + ((a + b) >> 1)) & 0xFF
                elif ftype == 4:
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                    line[x] = (line[x] + pr) & 0xFF
                else:
                    raise SystemExit(f"bad PNG filter type {ftype}")
        rows.append(bytes(line))
        prev = line
    return width, height, rows


def pixel(row, x):
    i = x * 3
    return (row[i] << 16) | (row[i + 1] << 8) | row[i + 2]


def format_value(val, split, labels):
    """Render a 24-bit value, optionally split into labelled bitfields."""
    if not split:
        return f"0x{val:06X}"
    parts, shift = [], 24
    for i, width in enumerate(split):
        shift -= width
        field = (val >> shift) & ((1 << width) - 1)
        name = labels[i] if i < len(labels) else f"f{i}"
        parts.append(f"{name}=0x{field:0{(width + 3) // 4}X}({field})")
    return "  ".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("png")
    ap.add_argument("--mode", choices=("counters", "scanline", "raster"),
                    default="counters")
    ap.add_argument("--limit", type=int, default=0,
                    help="max entries to print (0 = all)")
    ap.add_argument("--split", default="",
                    help="colon-separated bit widths summing to <=24, e.g. 8:16")
    ap.add_argument("--labels", default="",
                    help="comma-separated names for --split fields")
    ap.add_argument("--column", type=int, default=-1,
                    help="scanline mode: pixel column to sample (default: mid-line)")
    ap.add_argument("-o", "--out", default="",
                    help="also write the full decode to this file")
    args = ap.parse_args()

    split = [int(w) for w in args.split.split(":") if w] if args.split else []
    if split and sum(split) > 24:
        raise SystemExit("--split widths must sum to at most 24")
    labels = [s.strip() for s in args.labels.split(",")] if args.labels else []

    width, height, rows = read_png_rows(args.png)
    lines = [f"# {args.png}: {width}x{height}, mode={args.mode}"]

    if args.mode == "counters":
        from collections import Counter
        hist = Counter()
        for row in rows:
            for x in range(width):
                hist[pixel(row, x)] += 1
        lines.append(f"# {len(hist)} distinct colours")
        for val, n in hist.most_common(args.limit or None):
            r, g, b = (val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF
            lines.append(f"  R={r:<3} G={g:<3} B=0x{b:02X}({b:<3})  "
                         f"{format_value(val, split, labels)}  pixels={n}")

    elif args.mode == "scanline":
        col = args.column if args.column >= 0 else width // 2
        n = args.limit or height
        for y in range(min(n, height)):
            lines.append(f"{y:4d}  {format_value(pixel(rows[y], col), split, labels)}")

    else:  # raster
        seq = [pixel(row, x) for row in rows for x in range(width)]
        runs = []
        for val in seq:
            if runs and runs[-1][0] == val:
                runs[-1][1] += 1
            else:
                runs.append([val, 1])
        lines.append(f"# {len(seq)} samples, {len(runs)} runs, "
                     f"min=0x{min(seq):06X} max=0x{max(seq):06X}")
        for i, (val, n) in enumerate(runs[: args.limit or len(runs)]):
            lines.append(f"{i:6d}  {format_value(val, split, labels)}  x{n}")

    text = "\n".join(lines)
    print(text)
    if args.out:
        open(args.out, "w").write(text + "\n")
        print(f"\n# wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
