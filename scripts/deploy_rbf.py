#!/usr/bin/env python3
"""Deploy a .rbf to the MiSTer, but only if the build that produced it succeeded.

WHY THIS EXISTS
---------------
On 2026-08-24 a Quartus build died mid-Fitter (a project file was edited while
it ran). Quartus left the PREVIOUS build's .rbf sitting in output_files/, the
deploy step copied that stale bitstream to the device under a new name, and the
verification screenshot came back looking perfectly healthy -- because it was
verifying the previous build. A green result against a stale artifact is worse
than a red one: it looks like evidence.

This is the same failure as piping validate_mra.py through `tail` and losing its
exit status. The guard is not "remember to check the log", it is "the deploy
refuses to run unless the build demonstrably succeeded".

Two independent checks, because either alone can be fooled:
  1. the build log contains Quartus's success line;
  2. the .rbf is not OLDER than the build log, which catches the case where a
     failed run leaves an earlier .rbf in place.

Usage:
    python scripts/deploy_rbf.py --log quartus_video.log \\
        --rbf output_files/Psikyo.rbf --name Arcade-Psikyo_20260840.rbf
"""
import argparse
import os
import subprocess
import sys

SUCCESS = "Full Compilation was successful"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="Quartus build log to verify")
    ap.add_argument("--rbf", default="output_files/Psikyo.rbf")
    ap.add_argument("--name", required=True, help="remote filename")
    ap.add_argument("--force", action="store_true",
                    help="deploy even if the checks fail (say why in your commit)")
    args = ap.parse_args()

    problems = []

    if not os.path.exists(args.log):
        problems.append("build log %s does not exist" % args.log)
    else:
        text = open(args.log, encoding="utf-8", errors="replace").read()
        if SUCCESS not in text:
            problems.append("build log does not contain %r -- the build FAILED" % SUCCESS)
            for line in text.splitlines():
                if line.startswith("Error ("):
                    problems.append("    " + line.strip()[:110])

    if not os.path.exists(args.rbf):
        problems.append("%s does not exist" % args.rbf)
    elif os.path.exists(args.log):
        rbf_t, log_t = os.path.getmtime(args.rbf), os.path.getmtime(args.log)
        if rbf_t < log_t - 900:
            problems.append(
                ".rbf is %d minutes older than the build log -- almost certainly "
                "left over from a PREVIOUS build" % int((log_t - rbf_t) / 60))

    if problems:
        print("REFUSING TO DEPLOY:")
        for p in problems:
            print("  %s" % p)
        if not args.force:
            print("\nNothing was copied. Fix the build, or pass --force deliberately.")
            return 1
        print("\n--force given; deploying anyway.")

    here = os.path.dirname(os.path.abspath(__file__))
    cmd = [sys.executable, os.path.join(here, "mister_hw_test.py"), "deploy",
           "--rbf", args.rbf, "--rbf-remote-name", args.name]
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    r = subprocess.run(cmd, env=env)
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
