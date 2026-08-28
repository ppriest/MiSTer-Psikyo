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


NATIVE_W, NATIVE_H = 320, 224   # this core's raw output -- rtl/psikyo_top.sv screen timing.
                                  # Every row/column index in this file (extract(), the vreg
                                  # word/palette offsets, everything) assumes the PNG is
                                  # pixel-exact at this resolution. If MiSTer's HDMI output is
                                  # running any integer/fractional scaling (the OSD's video mode,
                                  # NOT the core itself), the screenshot comes back scaled
                                  # (observed: 1440x1080, a non-integer 4.5x/4.82x split) and
                                  # every row this tool reads is silently the WRONG source row --
                                  # rows near the top still look plausible (small drift), rows
                                  # near the bottom are total garbage (even the ctl_echo band's
                                  # fixed 0xA5 marker byte came back 0x00). That looked exactly
                                  # like a real "layers never enabled" hardware bug until the
                                  # dimensions were actually checked. Refuse rather than repeat
                                  # that -- set the OSD's video output to 1:1/no scaling before
                                  # capturing, or pass --force to get a best-effort (unreliable)
                                  # decode anyway.


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('png')
    ap.add_argument('--label', default='vram')
    ap.add_argument('--outdir', default='debug/captures')
    ap.add_argument('--force', action='store_true',
                    help='decode anyway even if the capture is not %dx%d (unreliable -- '
                         'every row index below this size assumes native, unscaled '
                         'pixels)' % (NATIVE_W, NATIVE_H))
    args = ap.parse_args()

    W, H, rows = load_png(args.png)
    if (W, H) != (NATIVE_W, NATIVE_H) and not args.force:
        sys.exit(
            'REFUSING TO DECODE: %s is %dx%d, not the core\'s native %dx%d.\n'
            'This tool reads fixed row/column indices assuming a pixel-exact, unscaled\n'
            'capture -- fed a scaled screenshot, it produces PLAUSIBLE-LOOKING GARBAGE\n'
            '(this exact mismatch once read back as "both tilemap layers permanently\n'
            'disabled", which was actually just wrong-row sampling, not a real bug).\n\n'
            'Fix: in the MiSTer OSD, set video output/scaling to 1:1 (no scaling) before\n'
            'taking the screenshot, then retake it. Or pass --force to decode anyway\n'
            '(unreliable -- only use this if you understand the scale factor and are\n'
            'prepared to distrust the result).'
            % (args.png, W, H, NATIVE_W, NATIVE_H))
    if H < 32:
        sys.exit('capture is only %d rows; need at least 32 for the VRAM bands' % H)
    os.makedirs(args.outdir, exist_ok=True)

    print('%s : %dx%d' % (args.png, W, H))
    l0 = extract(rows, 0, 16, W)
    l1 = extract(rows, 16, 16, W)
    c0 = report(l0, 0, args.label, args.outdir)
    print()
    c1 = report(l1, 1, args.label, args.outdir)

    # ---- palette (rows 48..63) ----
    if H >= 64:
        pal = extract(rows, 48, 16, W)
        pbase = os.path.join(args.outdir, '%s_palette.bin' % args.label)
        with open(pbase, 'wb') as fh:
            for w in pal:
                fh.write(struct.pack('<H', w))
        nz = sum(1 for x in pal if x)
        print()
        print('PALETTE: %d entries, %d non-zero, %d distinct  -> %s'
              % (len(pal), nz, len(set(pal)), pbase))
        # tiles live at 0x800 + colour*16, 72 colour groups (MAME GFXDECODE)
        for grp in (0, 1, 64, 65):
            base = 0x800 + grp * 16
            print('   tile colour %-3d @ %04X: %s'
                  % (grp, base, ' '.join('%04X' % pal[base + i] for i in range(8))))

    # ---- video registers (rows 32..47), if the capture carries them ----
    if H >= 48:
        vr = extract(rows, 32, 16, W)
        base = os.path.join(args.outdir, '%s_vregs.bin' % args.label)
        with open(base, 'wb') as fh:
            for w in vr:
                fh.write(struct.pack('<H', w))
        REGS = [(0x201, 'layer0 Y scroll'), (0x203, 'layer0 X scroll'),
                (0x205, 'layer1 Y scroll'), (0x207, 'layer1 X scroll'),
                (0x209, 'layer0 CONTROL'),  (0x20B, 'layer1 CONTROL')]
        print()
        print('VIDEO REGISTERS (word addresses, from the vregs BRAM itself)')
        print('=' * 64)
        for a, name in REGS:
            v = vr[a]
            line = '  %04X  %-16s = %04X' % (a, name, v)
            if 'CONTROL' in name:
                # enable is ACTIVE LOW (rtl/video/vreg_decode.sv: layer0_enable =
                # ~l0_ctrl[0], matching MAME's own
                # m_tilemap[layer]->enable(~layer_ctrl[layer] & 1)) -- bit0=0
                # means ENABLED. An earlier version of this tool read bit0
                # directly as enable (active-high), which made two genuinely
                # active, correctly-rendering layers (control word 0x00D0, bit0
                # clear) print as "enable=0" -- indistinguishable from a real
                # "layers never enabled" bug until the RTL was actually checked.
                enable = 1 - (v & 1)
                line += ('   enable=%d opaque=%d transp=%s size=%d rowscroll=%d'
                         ' pertile=%d bank=%d'
                         % (enable, (v >> 1) & 1, 'pen0' if (v >> 3) & 1 else 'pen15',
                            (v >> 6) & 3, (v >> 8) & 1, (v >> 9) & 1, (v >> 10) & 1))
            print(line)
        rs0 = vr[0x000:0x100]
        rs1 = vr[0x100:0x200]
        print('  rowscroll layer0 (0x000-0x0FF): %d non-zero, %d distinct'
              % (sum(1 for x in rs0 if x), len(set(rs0))))
        print('  rowscroll layer1 (0x100-0x1FF): %d non-zero, %d distinct'
              % (sum(1 for x in rs1 if x), len(set(rs1))))
        print('  -> %s' % base)
        l0_enabled = not (vr[0x209] & 1)
        l1_enabled = not (vr[0x20B] & 1)
        if not l0_enabled and not l1_enabled:
            print()
            print('  BOTH LAYERS READ AS DISABLED (enable is active-low: bit0=1 means')
            print('  off). If unexpected, check whether the CPU wrote these control')
            print('  words at all -- e.g. compare against a fresh 0x0000 capture --')
            print('  rather than assume vreg_decode is failing to latch them.')

    print()
    if len(c0) <= 1 and len(c1) <= 1:
        print('WARNING: both layers read as a single repeated value. Either the '
              'overlay was off (so the read ports were never borrowed), or the '
              'band mapping is wrong -- check the 0xA5 marker in the control '
              'echo band with scripts/decode_trace.py before trusting this.')


if __name__ == '__main__':
    main()
