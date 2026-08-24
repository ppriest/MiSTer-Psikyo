#!/usr/bin/env python3
"""Measure game-logic speed from the period of the attract-mode loop.

WHY THIS EXISTS
---------------
"Is the game running at half speed?" is harder to measure than it looks, and
two obvious methods both fail:

1. Diffing two screenshots. Any two frames of a running attract sequence differ
   in nearly every pixel, so the metric returns "100% changed" at 1x, 0.5x or
   4x alike. It measures "is something moving", not how fast.

2. Timing scene transitions. Sound in principle -- they are game-logic events,
   so at half rate the intervals double -- but a screenshot over the MiSTer
   Remote API costs about 2.3 s, and attract scenes change about that often.
   The sampler aliases and reports a cut at nearly every sample. Measured, not
   assumed: the first run of this script produced "cuts" at 2.2 s spacing with
   a 2.31 s sample period, which is the sampler's own rate showing through.

What a slow sampler *can* resolve is a long period. The attract sequence loops
every couple of minutes, and that loop period is pure game time: at half speed
it doubles. So capture several minutes, then find the lag that best re-aligns
the frame sequence with itself. No reference implementation is needed -- one
hardware run is A/B'd against another on the same bitstream.

Capture is neither instantaneous nor evenly spaced, so each frame carries the
wall-clock time it was taken and lags are matched against those timestamps
rather than against frame indices.

Usage:
    python scripts/attract_timeline.py --core samuraia \\
        --mra "/media/fat/_Arcade/_Psikyo/Samurai Aces (World).mra" \\
        --label bit53_zero --duration 300
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from decode_vram import load_png  # noqa: E402

GRID = 24          # coarse hash resolution
LEVELS = 6         # luminance quantisation


def coarse_hash(path):
    """Downsample to GRID x GRID quantised luminance cells."""
    w, h, rows = load_png(path)
    cells = []
    for gy in range(GRID):
        y = min(h - 1, gy * h // GRID)
        row = rows[y]
        for gx in range(GRID):
            x = min(w - 1, gx * w // GRID)
            r, g, b = row[x * 3], row[x * 3 + 1], row[x * 3 + 2]
            lum = (r * 299 + g * 587 + b * 114) // 1000
            cells.append(lum * LEVELS // 256)
    return cells


def cell_diff(a, b):
    return sum(1 for x, y in zip(a, b) if x != y) / float(len(a))


def find_period(frames, min_lag, max_lag, tol):
    """Best lag at which the frame sequence re-aligns with itself.

    For each candidate lag, pair every frame with the frame nearest to
    t + lag (rejecting the pair if nothing falls within `tol`), and score the
    mean similarity of those pairs. A loop of period P scores highly at P.
    Lags are searched in seconds, not frame counts, because sampling is uneven.
    """
    if len(frames) < 8:
        return None, []
    times = [f[0] for f in frames]
    curve = []
    lag = min_lag
    while lag <= max_lag:
        sims, j = [], 0
        for i, t in enumerate(times):
            target = t + lag
            if target > times[-1]:
                break
            while j + 1 < len(times) and abs(times[j + 1] - target) < abs(times[j] - target):
                j += 1
            if abs(times[j] - target) <= tol:
                sims.append(1.0 - cell_diff(frames[i][2], frames[j][2]))
        # Too few overlapping pairs at long lags to be meaningful.
        if len(sims) >= 6:
            curve.append((lag, sum(sims) / len(sims), len(sims)))
        lag += 1.0

    if not curve:
        return None, []
    best = max(curve, key=lambda c: c[1])
    baseline = sum(c[1] for c in curve) / len(curve)
    # Only call it a period if the peak stands clear of the average lag score;
    # otherwise every lag matches equally well and there is no loop to find.
    if best[1] < baseline + 0.05:
        return None, curve
    return (best[0], best[1]), curve


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--mra", help="launch this .mra first; omit to sample what is already running")
    ap.add_argument("--label", required=True, help="names the output files")
    ap.add_argument("--duration", type=float, default=60.0)
    ap.add_argument("--boot-seconds", type=float, default=22.0,
                    help="wait this long after launch before the first sample")
    ap.add_argument("--outdir", default="debug")
    ap.add_argument("--min-lag", type=float, default=15.0)
    ap.add_argument("--max-lag", type=float, default=180.0)
    ap.add_argument("--tol", type=float, default=1.2,
                    help="how close a frame must fall to t+lag to be paired (s)")
    args = ap.parse_args()

    shots = os.path.join(args.outdir, "attract_%s" % args.label)
    os.makedirs(shots, exist_ok=True)
    env = dict(os.environ, MSYS_NO_PATHCONV="1")

    if args.mra:
        for path, wait in (("/media/fat/menu.rbf", 8), (args.mra, args.boot_seconds)):
            subprocess.run([sys.executable, os.path.join(HERE, "mister_hw_test.py"),
                            "launch", "--mra", path], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(wait)

    t0 = time.time()
    frames = []
    n = 0
    while time.time() - t0 < args.duration:
        png = os.path.join(shots, "f%03d.png" % n)
        r = subprocess.run([sys.executable, os.path.join(HERE, "mister_hw_test.py"),
                            "screenshot", "--core", args.core, "--out", png,
                            "--settle-seconds", "0"], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t = time.time() - t0
        if r.returncode == 0 and os.path.exists(png):
            frames.append((t, png, coarse_hash(png)))
            n += 1

    period, curve = find_period(frames, args.min_lag, args.max_lag, args.tol)

    report = os.path.join(args.outdir, "attract_%s.txt" % args.label)
    with open(report, "w") as fh:
        fh.write("core=%s label=%s duration=%.1fs frames=%d\n"
                 % (args.core, args.label, args.duration, len(frames)))
        fh.write("grid=%d levels=%d\n\n" % (GRID, LEVELS))
        fh.write("%8s %8s  %s\n" % ("t(s)", "diff", "frame"))
        for i, (t, png, h) in enumerate(frames):
            d = cell_diff(frames[i - 1][2], h) if i else 0.0
            fh.write("%8.2f %8.3f  %s\n" % (t, d, os.path.basename(png)))

        fh.write("\nself-similarity vs lag (higher = better re-alignment):\n")
        for lag, sim, pairs in curve:
            bar = "#" * int(sim * 50)
            fh.write("  lag %6.1fs  sim %.3f  n=%-3d %s\n" % (lag, sim, pairs, bar))

        if period:
            fh.write("\nBEST LAG: %.1f s (similarity %.3f)\n" % period)
        else:
            fh.write("\nNo clear repeat found in this window.\n")
        fh.write("sample period: %.2f s mean\n"
                 % ((frames[-1][0] / (len(frames) - 1)) if len(frames) > 1 else 0.0))

    print(open(report).read()[-1400:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
