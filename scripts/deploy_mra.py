#!/usr/bin/env python3
"""Validate an .mra and only then copy it to the MiSTer.

WHY THIS EXISTS AS A SCRIPT
---------------------------
scripts/validate_mra.py already existed and already caught the problem, but it
was invoked as `validate_mra.py ... | tail -1` in a deploy one-liner -- piping
through tail discards the exit status, so a FAIL scrolled past and the broken
file went to the device anyway. A gate you have to remember to honour is not a
gate. This does the check and the copy as one operation, so the check cannot be
skipped by accident.

A malformed .mra does not fail loudly on the MiSTer: the DIP menu silently
disappears, no ROM is loaded, and the core comes up on a black screen with
SP=PC=00000000 -- symptoms that look exactly like an RTL regression and cost a
debugging round trip to attribute.

Usage:
    python scripts/deploy_mra.py "releases/Samurai Aces (World).mra"
    python scripts/deploy_mra.py releases/*.mra --dest /media/fat/_Arcade/_Psikyo

Credentials come from the environment (MISTER_HOST / MISTER_USER /
MISTER_PASSWORD), same as scripts/mister_hw_test.py -- never hardcoded.
"""
import argparse
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_mra  # noqa: E402


def find_pscp():
    for name in ("pscp.exe", "pscp"):
        p = shutil.which(name)
        if p:
            return p
    for p in (r"C:\Program Files\PuTTY\pscp.exe",
              r"C:\Program Files (x86)\PuTTY\pscp.exe"):
        if os.path.exists(p):
            return p
    sys.exit("pscp not found on PATH -- needed to copy files to the MiSTer")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--dest", default="/media/fat/_Arcade/_Psikyo")
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST"))
    ap.add_argument("--user", default=os.environ.get("MISTER_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("MISTER_PASSWORD"))
    ap.add_argument("--check-only", action="store_true",
                    help="validate and report, copy nothing")
    args = ap.parse_args()

    bad = 0
    for f in args.files:
        problems = validate_mra.check(f)
        if problems:
            bad += 1
            print("FAIL  %s" % f)
            for p in problems:
                print("        %s" % p)
        else:
            print("OK    %s" % f)

    if bad:
        print("\n%d file(s) failed validation. NOTHING was deployed." % bad)
        return 1
    if args.check_only:
        print("\nvalidation only; nothing copied.")
        return 0

    if not args.host or not args.password:
        sys.exit("set MISTER_HOST and MISTER_PASSWORD (see mister.env)")

    pscp = find_pscp()
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    for f in args.files:
        target = "%s@%s:%s/%s" % (args.user, args.host, args.dest.rstrip("/"),
                                  os.path.basename(f))
        r = subprocess.run([pscp, "-batch", "-pw", args.password, f, target],
                           capture_output=True, text=True, env=env)
        if r.returncode:
            print("COPY FAILED %s\n%s" % (f, (r.stderr or r.stdout).strip()))
            return 1
        print("deployed -> %s" % target)

    print("\nNOTE: MiSTer caches the loaded ROM. Bounce through the menu to "
          "force a re-read:\n"
          "  POST /api/launch {\"path\":\"/media/fat/menu.rbf\"}  then the .mra")
    return 0


if __name__ == "__main__":
    sys.exit(main())
