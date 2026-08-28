#!/usr/bin/env python3
"""Decode a VGA-debug-tap screenshot into a full trace, and ALWAYS save it.

Every capture is written to debug/captures/ under a name built from the trace
type and the settings it was taken with (mode, source, window/skip), so runs
never overwrite each other and a capture can be compared against one taken
earlier under different settings. Comparing two captures is most of the work in
this kind of bring-up; keeping only the last one throws that away.

The core's overlay layout (rtl/psikyo_core.sv's dbg_pixel mux):
    scanlines   0-15  : layer 0 VRAM
    scanlines  16-31  : layer 1 VRAM
    scanlines  32-47  : video registers
    scanlines  48-63  : palette RAM
    scanlines  64-191 : full 19-bit CPU ROM word address, one per read (128)
    scanlines 192-214 : {addr[7:0], data[15:0]} for the SAME read N (23)
    scanline     215  : worst-case sprite render length, in clk cycles
    scanlines 216-223 : control echo, 0xA5 marker + the settings the core sees

The palette band at 48-63 was added later and displaced the CPU bands; this
decoder was not updated with it and reported BAND MISALIGNED for every entry,
which made the CPU trace unreadable exactly when it was needed to debug a core
that would not boot. If the mux above changes, change these ranges with it.

Because both buffers are strobed by the same event, entry N of the address band
and entry N of the data band describe one bus cycle, which is what lets the
data be checked against the ROM at its true address.

Usage:
    python scripts/decode_trace.py cap.png [--label boot] [--rom roms/samuraia.zip]
"""
import argparse
import os
import struct
import zlib


def load_png(path):
    d = open(path, 'rb').read()
    pos, idat, W, H = 8, b'', None, None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        if typ == b'IHDR':
            W, H, _bd, ct = struct.unpack('>IIBB', d[pos + 8:pos + 18])
            if ct != 2:
                raise SystemExit('expected truecolour PNG (colourtype 2), got %d' % ct)
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


def sample(rows, y, x=4):
    """One pixel per scanline is the whole payload -- the tap drives the entire
    line with the same value, so any x within the active area works."""
    r = rows[y]
    return (r[x * 3] << 16) | (r[x * 3 + 1] << 8) | r[x * 3 + 2]


def rom_reader(zip_path, parts):
    import zipfile
    z = zipfile.ZipFile(zip_path)
    names = {n.lower(): n for n in z.namelist()}
    P = [z.read(names[p.lower()]) for p in parts]

    def word(w, even_idx=0, be=False):
        n = w >> 1
        p = P[even_idx] if w % 2 == 0 else P[1 - even_idx]
        if 2 * n + 1 >= len(p):
            return None
        return (p[2 * n] << 8) | p[2 * n + 1] if be else (p[2 * n + 1] << 8) | p[2 * n]
    return word


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('png')
    ap.add_argument('--label', default='cap', help='short tag for the filename')
    ap.add_argument('--rom', help='ROM zip, to check data against the real ROM')
    ap.add_argument('--parts', nargs=2, default=['4-u127.bin', '5-u126.bin'])
    ap.add_argument('--outdir', default='debug/captures')
    args = ap.parse_args()

    W, H, rows = load_png(args.png)
    # Band layout must track rtl/psikyo_core.sv's dbg_pixel mux:
    #   0-15 layer0 VRAM | 16-31 layer1 VRAM | 32-47 vregs | 48-63 palette
    #   64-191 CPU addr | 192-214 CPU addr+data | 215 sp_render_max
    #   216-223 control echo
    addr = [sample(rows, y) for y in range(64, min(192, H))]
    data = [sample(rows, y) for y in range(192, min(215, H))]
    echo = sample(rows, 218) if H > 218 else 0

    marker = echo >> 16
    # middle byte: {2'd0, l0_overrun, l1_overrun, l0_enable, l1_enable, frz_a, frz_d}
    l0_ovr, l1_ovr = (echo >> 13) & 1, (echo >> 12) & 1
    l0_en,  l1_en  = (echo >> 11) & 1, (echo >> 10) & 1
    frz_a, frz_d = (echo >> 9) & 1, (echo >> 8) & 1
    rearm = (echo >> 7) & 1
    window = (echo >> 3) & 0xF
    src = (echo >> 1) & 3
    ring = src & 1
    trig = (src >> 1) & 1
    skip = window * 8191

    os.makedirs(args.outdir, exist_ok=True)
    mode = 'ring' if ring else 'firstN'
    name = '%s_%s%s_win%d_skip%d.txt' % (
        args.label, mode, '_trig' if trig else '', window, skip)
    out = os.path.join(args.outdir, name)

    lines = []
    lines.append('capture      : %s' % args.png)
    lines.append('control echo : %06X  marker=%02X %s' %
                 (echo, marker, 'OK' if marker == 0xA5 else '*** BAD -- decode suspect ***'))
    lines.append('  mode       : %s%s' % (mode, ' + trigger-freeze' if trig else ''))
    lines.append('  window     : %d  (skip %d events)' % (window, skip))
    lines.append('  frozen     : addr=%d data=%d   rearm=%d' % (frz_a, frz_d, rearm))
    lines.append('  tilemaps   : layer0 enable=%d overrun=%d | layer1 enable=%d overrun=%d'
                 % (l0_en, l0_ovr, l1_en, l1_ovr))
    if l0_ovr or l1_ovr:
        lines.append('               ^ OVERRUN IS STICKY: a line engine wanted a pixel whose'
                     ' tile was not fetched yet,')
        lines.append('                 so it dropped pixel_valid and the compositor painted'
                     ' backdrop instead.')
    lines.append('  entries    : addr=%d data=%d' % (len(addr), len(data)))

    romw = rom_reader(args.rom, args.parts) if args.rom else None
    if romw:
        for be in (False, True):
            hits = sum(1 for i in range(min(len(addr), len(data)))
                       if romw(addr[i], 0, be) == (data[i] & 0xFFFF))
            lines.append('  ROM match  : %-13s %d/%d' %
                         ('big-endian' if be else 'little-endian',
                          hits, min(len(addr), len(data))))

    uniq = len(set(addr))
    lines.append('  addr range : %05X..%05X   distinct=%d%s' %
                 (min(addr), max(addr), uniq,
                  '   <-- TIGHT LOOP' if uniq <= 16 else ''))
    lines.append('')
    lines.append('   idx    addr    alo  data   rom(LE)  note')
    lines.append('   ---    -----   ---  ----   -------  ----')
    for i in range(len(addr)):
        a = addr[i]
        if i < len(data):
            alo, d = (data[i] >> 16) & 0xFF, data[i] & 0xFFFF
            exp = romw(a, 0, False) if romw else None
            note = ''
            if (a & 0xFF) != alo:
                note = 'BAND MISALIGNED'
            elif exp is not None and exp != d:
                note = 'MISMATCH'
            lines.append('   %3d   %05X    %02X  %04X   %s  %s' %
                         (i, a, alo, d, ('%04X' % exp) if exp is not None else '  -  ', note))
        else:
            lines.append('   %3d   %05X' % (i, a))

    text = '\n'.join(lines)
    open(out, 'w').write(text + '\n')
    print(text)
    print('\nsaved -> %s' % out)


if __name__ == '__main__':
    main()
