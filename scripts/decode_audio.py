#!/usr/bin/env python3
"""Analyse (and optionally convert to WAV) an audio capture dumped by
scripts/read_audio.tcl.

The point of this is to turn "it sounds scratchy" into a mechanism. Each check
below distinguishes a DIFFERENT cause, so the combination that fires tells you
where to look rather than merely confirming something is wrong:

  discontinuities   large sample-to-sample jumps. Clicks. If they coincide with
                    full-scale values it is clipping/overflow; if they appear at
                    ordinary amplitudes it is a decode or fetch fault.
  repeated samples  the same value held for several consecutive ticks. The
                    signature of a STARVED stream -- the chip re-emitting the
                    last sample because new data did not arrive.
  zero runs         silence gaps. Underrun, or a channel dropping out.
  rail hits         samples at +/-32767/32768. Clipping.
  periodicity       the interval between artefacts. A regular interval points at
                    a buffer or sample-rate boundary; irregular points at
                    content-dependent behaviour like overflow on loud passages.
  hf roughness      per-window high-frequency content (mean|d2|/mean|d1|). THE
                    one that actually matters for the YM2610 fault, and the
                    only check here that was not written for a hypothesis that
                    has since died. A late ADPCM-A sample byte does not click
                    and does not clip: it perturbs the decoder's accumulator
                    AND its adaptive step index, so the error is injected as
                    ROUGHNESS on top of the music and then decays over tens of
                    samples. Peak barely moves, rms moves a little, d2/d1 moves
                    a lot -- measured at 0.50 baseline against 0.78 around a
                    late fetch, and 0.685 against 0.928 in the first capture.
                    Everything above would call such a buffer clean, and did.

Usage:
    python scripts/decode_audio.py capture.bin
    python scripts/decode_audio.py capture.bin --wav out.wav
    python scripts/decode_audio.py capture.bin --rate 55500 --wav out.wav

The YM2610's output rate depends on the master clock; ~55.5 kHz is the usual
figure for an 8 MHz part. The rate only affects the WAV playback speed and the
millisecond figures, not the defect detection.
"""
import argparse
import math
import struct
import sys
import wave


def load(path):
    """Raw dumps from read_audio.tcl, or a .wav (so a capture off the video
    output can be run through the same checks as the internal one)."""
    if path.lower().endswith(".wav"):
        with wave.open(path, "rb") as w:
            if w.getsampwidth() != 2:
                sys.exit("only 16-bit WAV supported, got %d-bit" % (8 * w.getsampwidth()))
            ch = w.getnchannels()
            frames = w.readframes(w.getnframes())
            vals = struct.unpack("<%dh" % (len(frames) // 2), frames)
            if ch == 1:
                return list(zip(vals, vals)), w.getframerate()
            return list(zip(vals[0::ch], vals[1::ch])), w.getframerate()
    with open(path, "rb") as fh:
        raw = fh.read()
    n = len(raw) // 4
    if n == 0:
        sys.exit("%s is empty or too short" % path)
    vals = struct.unpack("<%dh" % (n * 2), raw[: n * 4])
    return list(zip(vals[0::2], vals[1::2])), None


def window_stats(ch, rate, nwin=8):
    """Per-window rms and difference ratios.

    d1/rms is how jagged the signal is relative to its size; d2/d1 is how
    jagged the JAGGEDNESS is, which is what isolates injected roughness from
    a merely loud passage -- a loud clean passage raises rms and d1 together
    and leaves d2/d1 flat, while corrupted ADPCM nibbles raise d2/d1 on its
    own. Report both so the two cases stay distinguishable.
    """
    out = []
    n = len(ch)
    step = max(1, n // nwin)
    for a in range(0, n, step):
        w = ch[a:a + step]
        if len(w) < 4:
            continue
        rms = math.sqrt(sum(x * x for x in w) / len(w)) or 1e-9
        d1 = [w[i] - w[i - 1] for i in range(1, len(w))]
        d2 = [d1[i] - d1[i - 1] for i in range(1, len(d1))]
        m1 = sum(abs(x) for x in d1) / len(d1) or 1e-9
        m2 = sum(abs(x) for x in d2) / len(d2)
        out.append((a / rate, (a + len(w)) / rate, rms, m1 / rms, m2 / m1))
    return out


def runs_of_equal(seq):
    """(start_index, length, value) for every run of >= 2 identical samples."""
    out = []
    i = 0
    while i < len(seq):
        j = i + 1
        while j < len(seq) and seq[j] == seq[i]:
            j += 1
        if j - i >= 2:
            out.append((i, j - i, seq[i]))
        i = j
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--rate", type=int, default=55500,
                    help="sample rate in Hz, for WAV output and ms figures")
    ap.add_argument("--wav", default="", help="also write a WAV file here")
    ap.add_argument("--jump", type=int, default=8000,
                    help="sample-to-sample delta counted as a discontinuity")
    ap.add_argument("--start", type=float, default=0.0, help="analyse from this second")
    ap.add_argument("--end", type=float, default=0.0, help="analyse up to this second (0 = end)")
    args = ap.parse_args()

    frames, wav_rate = load(args.capture)
    if wav_rate:
        args.rate = wav_rate
    if args.start or args.end:
        a = int(args.start * args.rate)
        b = int(args.end * args.rate) if args.end else len(frames)
        frames = frames[a:b]
        print("window: %.2f s .. %.2f s" % (args.start, args.end or len(frames) / args.rate))
    n = len(frames)
    left = [f[0] for f in frames]
    right = [f[1] for f in frames]
    ms = 1000.0 * n / args.rate

    print("%s: %d stereo samples, %.1f ms at %d Hz" % (args.capture, n, ms, args.rate))

    for name, ch in (("left", left), ("right", right)):
        peak = max(abs(v) for v in ch)
        rails = sum(1 for v in ch if v >= 32767 or v <= -32768)
        nz = [v for v in ch if v != 0]
        print("\n-- %s --" % name)
        print("  peak |sample| : %d (%.1f%% of full scale)" % (peak, 100.0 * peak / 32768))
        print("  at the rails  : %d (%.2f%%)" % (rails, 100.0 * rails / n))
        print("  all-zero      : %d (%.2f%%)" % (n - len(nz), 100.0 * (n - len(nz)) / n))

        jumps = [i for i in range(1, n) if abs(ch[i] - ch[i - 1]) >= args.jump]
        print("  discontinuities (|delta| >= %d): %d" % (args.jump, len(jumps)))
        if jumps:
            # A sign flip between two large values is the overflow-wrap
            # signature specifically, as opposed to a merely loud transient.
            wraps = [i for i in jumps
                     if (ch[i - 1] > 24576 and ch[i] < -24576)
                     or (ch[i - 1] < -24576 and ch[i] > 24576)]
            print("    of which full-scale sign flips (wrap signature): %d" % len(wraps))
            gaps = [jumps[i] - jumps[i - 1] for i in range(1, len(jumps))]
            if gaps:
                gaps_sorted = sorted(gaps)
                med = gaps_sorted[len(gaps_sorted) // 2]
                same = sum(1 for g in gaps if abs(g - med) <= 1)
                print("    median gap between them: %d samples (%.2f ms)"
                      % (med, 1000.0 * med / args.rate))
                print("    gaps within +/-1 of the median: %d/%d %s"
                      % (same, len(gaps),
                         "-- REGULAR, suspect a buffer/rate boundary"
                         if same > len(gaps) * 0.6
                         else "-- irregular, suspect content-dependent behaviour"))
            print("    first few at samples: %s" % jumps[:8])

        wins = window_stats(ch, args.rate)
        if wins:
            base = min(w[4] for w in wins)
            worst = max(wins, key=lambda w: w[4])
            print("  hf roughness d2/d1 by window (baseline %.3f, worst %.3f):"
                  % (base, worst[4]))
            for a, b, rms, r1, r2 in wins:
                flag = " <-- ROUGH" if r2 > base * 1.35 else ""
                print("    %6.1f-%6.1f ms  rms %6.0f  d1/rms %.3f  d2/d1 %.3f%s"
                      % (1000 * a, 1000 * b, rms, r1, r2, flag))
            if worst[4] > base * 1.35:
                print("    -> roughness rises %.0f%% above baseline without the peak"
                      % (100 * (worst[4] / base - 1)))
                print("       following it. That is injected noise (corrupted ADPCM "
                      "nibbles), NOT clipping -- clipping moves the peak first.")

        rep = [r for r in runs_of_equal(ch) if r[1] >= 3]
        held = sum(r[1] for r in rep)
        print("  repeated-sample runs (>=3): %d, covering %d samples (%.2f%%)"
              % (len(rep), held, 100.0 * held / n))
        if rep:
            longest = max(rep, key=lambda r: r[1])
            print("    longest run: %d samples at index %d (value %d)"
                  % (longest[1], longest[0], longest[2]))

    if args.wav:
        with wave.open(args.wav, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(args.rate)
            w.writeframes(b"".join(struct.pack("<hh", l, r) for l, r in frames))
        print("\nwrote %s" % args.wav)


if __name__ == "__main__":
    main()
