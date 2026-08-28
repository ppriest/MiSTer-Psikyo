#!/usr/bin/env python3
"""Set/clear OSD status bits in a MiSTer per-core .CFG -- WITHOUT wiping it.

WHY THIS EXISTS
---------------
/media/fat/config/<setname>.CFG is the whole 128-bit status word,
little-endian (byte N holds status[8N+7:8N]). The DIP switches from the
.mra's <switches> block live in that SAME word (bytes 2-4, status[39:16]).
Writing 16 bytes with only a debug bit set therefore zeroes every DIP --
which for this core turns Service Mode ON (byte 2 bit 7, ids "On,Off", so
0 = On) and boots the game into its RAM-check screen instead of attract.
That exact mistake is documented in docs/LESSONS_LEARNED.md ("Writing a
.CFG by hand rewrites the DIP switches") and was then made AGAIN on
2026-08-29, zeroing samuraia.CFG and gunbird.CFG during debug-bit pokes.
Hence this tool: it read-modify-writes the existing file, so untouched
bits -- DIPs included -- survive.

Modes:
  * Existing CFG on the device: pulled, patched, pushed back.
  * No CFG / --reset: built from per-game DIP defaults (see DIP_DEFAULTS)
    plus flip_180 ON -- this project's screen is rotated, so a cleared CFG
    that boots unflipped is "wrong by default" here (user directive
    2026-08-29: set flipscreen by default when clearing the .cfg).

Status-bit map (from Psikyo.sv -- keep in sync if bits move):
  0        reset
  16-39    DIP switches (from the .mra <switches>; byte2 bit7 = Service Mode)
  40/41/42 render disable: sprites / tilemap 0 / tilemap 1  (1 = off)
  43       sprite swap policy (0 EndOfRender, 1 FrameStart)
  44-46    scandoubler fx        47-48  rotation (0 off, 1 CW, 2 CCW)
  49       flip_180              50     VRAM write auto-pause
  51       sound IRQ DISABLE (inverted: 0=on since 2026-08-29)
  53       C00008 bit0 (0 zero, 1 vblank)
  54       frame-count auto-pause
  56       trace overlay         57-58  trace source
  59-62    trace window          63     re-arm capture (toggle)
  121-122  aspect ratio

DIP defaults (docs/LESSONS_LEARNED.md, measured + confirmed against
psikyo.cpp): bytes 2,3,4 = FD,FF,FF for samuraia/gunbird-family, FD,FF,00
for btlkroad (its region jumper encodes World as 0x00). A 0xFF region byte
hangs gunbird's boot ($C00004 bit-7 spin), so the right fix for a zeroed
CFG is these defaults, never all-FF.

Usage (credentials via mister.env / MISTER_* env vars, same as
mister_hw_test.py):
    python scripts/write_cfg.py samuraia --set overlay --clear 56
    python scripts/write_cfg.py gunbird --repair-dips   # fix zeroed DIPs only
    python scripts/write_cfg.py samuraia --reset        # defaults + flip_180
    python scripts/write_cfg.py samuraia                # show current bits

Named bits accepted by --set/--clear (or use raw bit numbers):
    sprites_off=40 tilemap0_off=41 tilemap1_off=42 sprite_swap=43
    flip=49 vram_autopause=50 snd_irq_off=51 c00008_vblank=53
    frame_autopause=54 overlay=56 rearm=63
"""
import argparse
import os
import subprocess
import sys
import tempfile

NAMED_BITS = {
    "sprites_off": 40, "tilemap0_off": 41, "tilemap1_off": 42,
    "sprite_swap": 43, "flip": 49, "vram_autopause": 50, "snd_irq_off": 51,
    "c00008_vblank": 53, "frame_autopause": 54, "overlay": 56, "rearm": 63,
}

# bytes 2,3,4 = status[23:16], status[31:24], status[39:32] -- taken from each
# .mra's own <switches default="..."> attribute, the authority (NOT the prose
# in LESSONS_LEARNED, whose "FD,FF,FF for samuraia and gunbird" is wrong for
# gunbird: its region byte is 0F, and an FF there sets the $C00004 bit-7 its
# boot spins on until clear, so FF never boots). Region-alternate sets use a
# different <switches> layout (5-byte defaults) -- add them only after reading
# their .mra, don't copy a parent set's bytes.
DIP_DEFAULTS = {
    "samuraia": (0xFD, 0xFF, 0xFF),
    "gunbird":  (0xFD, 0xFF, 0x0F),
    "btlkroad": (0xFD, 0xFF, 0x00),
}

CFG_LEN = 16
FLIP_BIT = 49


def find_putty(name):
    for c in (os.path.join(r"C:\Program Files\PuTTY", name),
              os.path.join(r"C:\Program Files (x86)\PuTTY", name), name):
        if os.path.sep not in c or os.path.exists(c):
            return c
    return name


def parse_bit(s):
    s = s.strip().lower()
    if s in NAMED_BITS:
        return NAMED_BITS[s]
    b = int(s)
    if not (0 <= b < CFG_LEN * 8):
        raise ValueError("bit %d out of range" % b)
    if 16 <= b <= 39:
        raise ValueError(
            "bit %d is a DIP switch -- set DIPs via the OSD or --repair-dips, "
            "not by hand (see docs/LESSONS_LEARNED.md)" % b)
    return b


def describe(data):
    out = []
    for name, bit in sorted(NAMED_BITS.items(), key=lambda kv: kv[1]):
        if data[bit // 8] >> (bit % 8) & 1:
            out.append("%s(%d)" % (name, bit))
    dips = tuple(data[2:5])
    return "dips=%02X,%02X,%02X set:[%s]" % (dips[0], dips[1], dips[2],
                                             " ".join(out) or "-none-")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("setname", help="core setname, e.g. samuraia")
    ap.add_argument("--set", default="", help="comma-sep bits/names to set")
    ap.add_argument("--clear", default="", help="comma-sep bits/names to clear")
    ap.add_argument("--repair-dips", action="store_true",
                    help="rewrite ONLY the DIP bytes to this game's defaults")
    ap.add_argument("--reset", action="store_true",
                    help="rebuild from scratch: DIP defaults + flip_180 ON")
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST"))
    ap.add_argument("--user", default=os.environ.get("MISTER_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("MISTER_PASSWORD"))
    args = ap.parse_args()

    if not args.host or not args.password:
        sys.exit("need MISTER_HOST/MISTER_PASSWORD (source mister.env)")

    remote = "/media/fat/config/%s.CFG" % args.setname
    pscp = find_putty("pscp.exe")
    tmp = os.path.join(tempfile.gettempdir(), "%s.CFG" % args.setname)

    def scp(a, b):
        return subprocess.run(
            [pscp, "-batch", "-pw", args.password, a, b],
            capture_output=True, text=True,
            env=dict(os.environ, MSYS_NO_PATHCONV="1"))

    r = scp("%s@%s:%s" % (args.user, args.host, remote), tmp)
    existed = r.returncode == 0
    if existed and not args.reset:
        data = bytearray(open(tmp, "rb").read())
        if len(data) < CFG_LEN:
            data += b"\0" * (CFG_LEN - len(data))
    else:
        # From scratch (or --reset): DIP defaults + flip_180 ON, per header.
        if args.setname not in DIP_DEFAULTS:
            sys.exit("no DIP defaults known for %r -- add to DIP_DEFAULTS "
                     "from its .mra before using --reset" % args.setname)
        data = bytearray(CFG_LEN)
        data[2:5] = bytes(DIP_DEFAULTS[args.setname])
        data[FLIP_BIT // 8] |= 1 << (FLIP_BIT % 8)
        # Sound IRQ needs no seeding: since the 2026-08-29 inversion in
        # Psikyo.sv, status[51]=0 means ON (music playing), so a fresh
        # all-zero CFG is already right. Bit 51 SET disables it.

    before = bytes(data)
    print("%s: %s%s" % (args.setname, describe(data),
                        "" if existed else "  (no CFG on device: built fresh)"))

    if args.repair_dips:
        if args.setname not in DIP_DEFAULTS:
            sys.exit("no DIP defaults known for %r" % args.setname)
        data[2:5] = bytes(DIP_DEFAULTS[args.setname])

    for s in filter(None, args.set.split(",")):
        b = parse_bit(s)
        data[b // 8] |= 1 << (b % 8)
    for s in filter(None, args.clear.split(",")):
        b = parse_bit(s)
        data[b // 8] &= ~(1 << (b % 8))

    if bytes(data) == before and existed and not args.reset:
        print("no changes; nothing written")
        return 0

    open(tmp, "wb").write(bytes(data))
    r = scp(tmp, "%s@%s:%s" % (args.user, args.host, remote))
    if r.returncode != 0:
        sys.exit("push failed: %s" % r.stderr.strip())
    print("wrote:    %s" % describe(data))
    print("NOTE: the core reads its CFG at load -- relaunch the game "
          "(bounce through menu) for the change to take effect.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
