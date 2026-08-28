#!/usr/bin/env python3
"""Decode an 8KB spriteram dump: display list, attributes, priority breakdown.

Works on either side of the comparison the JTAG probe was built for:
  * hardware: scripts/read_spriteram.tcl dump <file>  (CPU-visible buffer)
  * MAME: debugger `save <file>,404000,2000` (same buffer, same 8KB shape)
Both are 4096 little-endian 16-bit words: attribute table words 0x000-0xBFF
(768 entries x 4 words), display list 0xC00-0xFFE (0xFFFF-terminated sprite
indices), control word 0xFFF.

Field layout mirrors rtl/video/sprite_record_decode.sv EXACTLY (which itself
mirrors MAME's psikyo_v.cpp) -- if that file changes, change this with it:
  w0: [15:12] zoom_y  [11:9] ny-1  [8:0] y (9-bit signed)
  w1: [15:12] zoom_x  [11:9] nx-1  [8:0] x (wraps >=384 to negative)
  w2: [15] flip_y  [14] flip_x  [12:8] color  [7:6] priority  [0] code bit 16
  w3: code[15:0]

Usage:
    python scripts/decode_spriteram.py dump.bin                 # summary
    python scripts/decode_spriteram.py dump.bin --pri 2         # only pri 2
    python scripts/decode_spriteram.py dump.bin --at 120 80     # sprites covering pixel
    python scripts/decode_spriteram.py dump.bin --code 5d69     # by tile code
Every run also appends nothing anywhere -- pipe to a file under debug/ to
persist an analysis (one file per capture, named for what it is).
"""
import argparse
import struct
import sys


def decode_entry(words, idx):
    w0, w1, w2, w3 = words[idx * 4: idx * 4 + 4]
    y = w0 & 0x1FF
    if y >= 256:
        y -= 512
    x = w1 & 0x1FF
    if x >= 384:
        x -= 512
    return {
        "idx": idx,
        "zoom_y": w0 >> 12, "ny": ((w0 >> 9) & 7) + 1, "y": y,
        "zoom_x": w1 >> 12, "nx": ((w1 >> 9) & 7) + 1, "x": x,
        "flip_y": w2 >> 15 & 1, "flip_x": w2 >> 14 & 1,
        "color": (w2 >> 8) & 0x1F, "pri": (w2 >> 6) & 3,
        "code": ((w2 & 1) << 16) | w3,
        "w": (w0, w1, w2, w3),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binfile")
    ap.add_argument("--pri", type=int, help="show only this priority")
    ap.add_argument("--at", nargs=2, type=int, metavar=("X", "Y"),
                    help="show sprites whose (unzoomed) bounds cover this pixel")
    ap.add_argument("--code", help="show only this tile code (hex)")
    ap.add_argument("--all", action="store_true", help="list every active sprite")
    args = ap.parse_args()

    raw = open(args.binfile, "rb").read()
    if len(raw) != 8192:
        sys.exit("expected 8192 bytes, got %d" % len(raw))
    words = struct.unpack("<4096H", raw)

    ctrl = words[0xFFF]
    print("control word 0xFFF = %04X  (sprites_disable=%d transpen_sel=%d)"
          % (ctrl, ctrl & 1, (ctrl >> 2) & 3))

    # walk the display list
    dl, seen = [], set()
    for i in range(0xC00, 0xFFF):
        v = words[i]
        if v == 0xFFFF:
            break
        dl.append(v & 0x3FF)
    print("display list: %d entries before terminator" % len(dl))

    sprites = [decode_entry(words, i) for i in dl]

    hist = {}
    for s in sprites:
        hist[s["pri"]] = hist.get(s["pri"], 0) + 1
    print("priority histogram: " +
          "  ".join("pri%d=%d" % (p, hist.get(p, 0)) for p in range(4)))

    sel = sprites
    if args.pri is not None:
        sel = [s for s in sel if s["pri"] == args.pri]
    if args.code:
        c = int(args.code, 16)
        sel = [s for s in sel if s["code"] == c]
    if args.at:
        px, py = args.at
        sel = [s for s in sel
               if s["x"] <= px < s["x"] + s["nx"] * 16
               and s["y"] <= py < s["y"] + s["ny"] * 16]
        print("sprites covering (%d,%d): %d" % (px, py, len(sel)))

    if args.pri is not None or args.code or args.at or args.all:
        print(" list#  entry   x    y  nx ny zx zy fx fy col pri  code   raw")
        for n, s in enumerate(sel):
            print("  %3d   0x%03X %4d %4d  %d  %d %2d %2d  %d  %d %3d   %d  %05X  %04X %04X %04X %04X"
                  % (dl.index(s["idx"]) if s["idx"] in dl else -1, s["idx"],
                     s["x"], s["y"], s["nx"], s["ny"], s["zoom_x"], s["zoom_y"],
                     s["flip_x"], s["flip_y"], s["color"], s["pri"], s["code"], *s["w"]))
    else:
        # summary: group by priority, show position spread + top codes
        for p in range(4):
            g = [s for s in sprites if s["pri"] == p]
            if not g:
                continue
            xs = [s["x"] for s in g]
            ys = [s["y"] for s in g]
            codes = {}
            for s in g:
                codes[s["code"]] = codes.get(s["code"], 0) + 1
            top = sorted(codes.items(), key=lambda kv: -kv[1])[:6]
            print("pri %d: n=%d  x %d..%d  y %d..%d  top codes: %s"
                  % (p, len(g), min(xs), max(xs), min(ys), max(ys),
                     " ".join("%05X x%d" % (c, n) for c, n in top)))


if __name__ == "__main__":
    main()
