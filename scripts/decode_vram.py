#!/usr/bin/env python3
"""Extract the tilemap VRAM dump from a debug-overlay screenshot.

The core's overlay puts both tilemap layers' complete VRAM in the top 32
scanlines (rtl/psikyo_core.sv): with the overlay on, the layer engines' VRAM
read ports are borrowed and addressed as {vcnt[3:0], hcnt[7:0]}, so

    rows  0-15, cols 0-255 -> layer 0 VRAM words 0x000-0xFFF
    rows 16-31, cols 0-255 -> layer 1 VRAM words 0x000-0xFFF

one screenshot therefore carries all 4096 words of each layer.

Each VRAM word is a tilemap cell, decoded by rtl/video/tile_cell_decode.sv as
    tile = cell[12:0] + 0x2000*bank      color = cell[15:13] + layer*0x40
so this also reports the tile/colour split, which is what you actually compare
against MAME.

Outputs (written next to the capture, under debug/captures/):
    <label>_l0.bin / <label>_l1.bin   raw 16-bit little-endian, 8192 bytes each
    <label>_l0.txt / <label>_l1.txt   hex dump with tile/colour decode

To compare against MAME, dump the same regions from its debugger
(layer 0 = 0x800000, layer 1 = 0x802000, 0x2000 bytes each), then just
`cmp` the .bin files.

Usage:
    python scripts/decode_vram.py debug/captures/cap.png --label boot
"""
import argparse
import os
import struct
import sys
import zlib
from collections import Counter


def load_png(path):
    d = open(path, 'rb').read()
    pos, idat, W, H = 8, b'', None, None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        if typ == b'IHDR':
            W, H, _bd, ct = struct.unpack('>IIBB', d[pos + 8:pos + 18])
            if ct != 2:
                sys.exit('expected truecolour PNG, got colourtype %d' % ct)
        elif typ == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp, stride = 3, W * 3
    rows, prev, o = [], bytearray(stride), 0
    for _y in range(H):
        f = raw[o]; o += 1
        line = bytearray(raw[o:o + stride]); o += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:   line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(bytes(line)); prev = line
    return W, H, rows


def extract(rows, row0, nrows, W):
    """16 rows x 256 cols -> 4096 words. Pixel carries the word in its low 16 bits."""
    words = []
    for r in range(row0, row0 + nrows):
        line = rows[r]
        for x in range(min(256, W)):
            g, b = line[x * 3 + 1], line[x * 3 + 2]
            words.append((g << 8) | b)
    return words


def report(words, layer, label, outdir):
    base = os.path.join(outdir, '%s_l%d' % (label, layer))
    with open(base + '.bin', 'wb') as fh:
        for w in words:
            fh.write(struct.pack('<H', w))

    nonzero = sum(1 for w in words if w)
    c = Counter(words)
    lines = []
    lines.append('layer %d : %d words, %d non-zero (%.1f%%), %d distinct'
                 % (layer, len(words), nonzero, 100.0 * nonzero / len(words), len(c)))
    lines.append('most common cells:')
    for w, n in c.most_common(8):
        lines.append('   %04X  x%-5d  tile=%04X color=%d'
                     % (w, n, w & 0x1FFF, (w >> 13) & 7))
    lines.append('')
    lines.append('  addr  | cells (tile:color)')
    for i in range(0, len(words), 16):
        chunk = words[i:i + 16]
        lines.append('  %04X  | ' % i + ' '.join('%04X' % w for w in chunk))
    text = '\n'.join(lines)
    open(base + '.txt', 'w').write(text + '\n')
    print(text.split('\n\n')[0])
    for l in lines[1:11]:
        print(l)
    print('  -> %s.bin (%d bytes), %s.txt' % (base, len(words) * 2, base))
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('png')
    ap.add_argument('--label', default='vram')
    ap.add_argument('--outdir', default='debug/captures')
    args = ap.parse_args()

    W, H, rows = load_png(args.png)
    if H < 32:
        sys.exit('capture is only %d rows; need at least 32 for the VRAM bands' % H)
    os.makedirs(args.outdir, exist_ok=True)

    print('%s : %dx%d' % (args.png, W, H))
    l0 = extract(rows, 0, 16, W)
    l1 = extract(rows, 16, 16, W)
    c0 = report(l0, 0, args.label, args.outdir)
    print()
    c1 = report(l1, 1, args.label, args.outdir)

    print()
    if len(c0) <= 1 and len(c1) <= 1:
        print('WARNING: both layers read as a single repeated value. Either the '
              'overlay was off (so the read ports were never borrowed), or the '
              'band mapping is wrong -- check the 0xA5 marker in the control '
              'echo band with scripts/decode_trace.py before trusting this.')


if __name__ == '__main__':
    main()
