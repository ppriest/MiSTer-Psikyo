#!/usr/bin/env python3
"""Build Quartus from a staged snapshot of HEAD, leaving the tree free.

Stages the current HEAD commit into a dedicated git worktree at <repo>/build
(gitignored) and runs the full Quartus flow THERE, so editing files in the
main tree during the ~14-minute compile can no longer corrupt the build --
and all of Quartus's scratch (db/, incremental_db/, output_files/, logs)
lives under build/ instead of cluttering the repo root. That is not hypothetical: scripts/deploy_rbf.py's header records
a build that died mid-Fitter when a project file was edited while it ran --
and the deploy step then verified the PREVIOUS build's stale .rbf as green.

The build is exactly HEAD:
  * a dirty tree is refused by default -- what you see in the editor and
    what the build compiles must not silently diverge. --allow-dirty
    builds HEAD anyway, explicitly acknowledging the edits are excluded.
  * the built commit hash is written to <stage>/BUILT_COMMIT next to the
    log, so every .rbf maps to one commit.

Launch it through the harness's own background tracking (no nohup, no &):
    python scripts/build_staged.py                # revision Psikyo_stp
    python scripts/build_staged.py --rev Psikyo   # release revision

Outputs land in the stage, never the main tree:
    <stage>/q_staged.log            build log (deploy gate reads this)
    <stage>/output_files/<rev>.rbf  the bitstream
    <stage>/BUILT_COMMIT            commit hash + timestamp

Deploy exactly as before, pointed at the stage:
    python scripts/deploy_rbf.py --log <stage>/q_staged.log \\
        --rbf <stage>/output_files/Psikyo_stp.rbf --name Arcade-Psikyo_NNN.rbf

The stage worktree persists between builds (Quartus's db/ with it, which
costs nothing for full compiles but avoids re-checkout churn); each run
hard-resets it to HEAD first. A .build_running marker guards against two
overlapping stage builds.
"""
import argparse
import datetime
import os
import subprocess
import sys

QUARTUS_BIN = os.environ.get(
    "QUARTUS_BIN", r"C:\intelFPGA_lite\17.0\quartus\bin64")


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("FAILED: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default="Psikyo_stp",
                    help="Quartus revision (default: Psikyo_stp, the "
                         "instrumented build -- the project default)")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="build HEAD even though the tree has uncommitted "
                         "changes (they are NOT included)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    stage = os.path.join(here, "build")

    dirty = run(["git", "-C", here, "status", "--porcelain"])
    if dirty and not args.allow_dirty:
        sys.exit("tree is dirty -- commit first (the build is exactly HEAD), "
                 "or pass --allow-dirty to build HEAD without these:\n" + dirty)

    head = run(["git", "-C", here, "rev-parse", "HEAD"])
    head_short = run(["git", "-C", here, "rev-parse", "--short", "HEAD"])

    marker = os.path.join(stage, ".build_running")
    if os.path.exists(marker):
        sys.exit("a staged build already appears to be running (%s exists) -- "
                 "wait for it, or delete the marker if it is stale" % marker)

    # Create or update the stage worktree to exactly HEAD.
    if not os.path.isdir(os.path.join(stage, ".git")) and \
       not os.path.isfile(os.path.join(stage, ".git")):
        run(["git", "-C", here, "worktree", "add", "--detach", stage, head])
    else:
        run(["git", "-C", stage, "checkout", "--detach", head])
        run(["git", "-C", stage, "reset", "--hard", head])

    stamp = "%s  %s\n" % (head, datetime.datetime.now().isoformat())
    open(os.path.join(stage, "BUILT_COMMIT"), "w").write(stamp)
    print("stage:  %s" % stage)
    print("commit: %s (%s)" % (head_short, head))
    print("rev:    %s" % args.rev)

    quartus = os.path.join(QUARTUS_BIN, "quartus_sh.exe")
    log_path = os.path.join(stage, "q_staged.log")
    open(marker, "w").write(stamp)
    try:
        with open(log_path, "w") as log:
            r = subprocess.run(
                [quartus, "--flow", "compile", "Psikyo", "-c", args.rev],
                cwd=stage, stdout=log, stderr=subprocess.STDOUT)
    finally:
        os.remove(marker)

    tail = open(log_path, errors="replace").read().splitlines()[-25:]
    ok = any("Full Compilation was successful" in ln for ln in tail)
    for ln in tail:
        if any(k in ln for k in ("successful", "Error", "Elapsed")):
            print(ln.strip())
    summary = os.path.join(stage, "output_files", "%s.sta.summary" % args.rev)
    if os.path.exists(summary):
        lines = open(summary).read().splitlines()
        for i, ln in enumerate(lines):
            if ln.startswith("Type  : Setup 'emu|pll"):
                print("worst clk_sys setup: %s / %s"
                      % (lines[i + 1].strip(), lines[i + 2].strip()))
                break
    if not ok:
        sys.exit("BUILD FAILED -- see %s" % log_path)
    print("OK -- deploy with:\n  python scripts/deploy_rbf.py --log \"%s\" "
          "--rbf \"%s\" --name Arcade-Psikyo_NNNNNNNN.rbf"
          % (log_path, os.path.join(stage, "output_files", "%s.rbf" % args.rev)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
