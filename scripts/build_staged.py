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
import re
import subprocess
import sys

QUARTUS_BIN = os.environ.get(
    "QUARTUS_BIN", r"C:\intelFPGA_lite\17.0\quartus\bin64")


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit("FAILED: %s\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout.strip()


def read_slacks(summary):
    """Print each clock's setup slack; return the ones that fail.

    Reads every Type/Slack/TNS triple rather than clk_sys alone, so a release
    is gated on the whole design -- a violation on any clock is a violation.
    """
    out = []
    if not os.path.exists(summary):
        print("no timing summary at %s -- treating as unverified" % summary)
        return out
    lines = open(summary, errors="replace").read().splitlines()
    for i, ln in enumerate(lines):
        if not ln.startswith("Type  : Setup ") or i + 2 >= len(lines):
            continue
        clk = ln.split("Setup ", 1)[1].strip().strip("'")
        try:
            slack = float(lines[i + 1].split(":", 1)[1])
        except (IndexError, ValueError):
            continue
        tns = lines[i + 2].split(":", 1)[1].strip()
        if "emu|pll" in clk:
            print("worst clk_sys setup: Slack : %.3f / TNS   : %s" % (slack, tns))
        if slack < 0:
            out.append((clk[-58:], slack, tns))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int,
                    help="override the fitter SEED in the staged .qsf "
                         "(placement only; try before restructuring RTL "
                         "for a sub-ns violation)")
    ap.add_argument("--allow-negative-slack", action="store_true",
                    help="publish a release build that fails timing; prints a "
                         "warning, and the shortfall must be stated in the "
                         "release notes")
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
        # --force: a seed sweep patches SEED into the STAGED .qsf, and a
        # leftover patch must never wedge the next build -- the stage is a
        # disposable copy of HEAD, local changes in it are always discardable
        run(["git", "-C", stage, "checkout", "--force", "--detach", head])
        run(["git", "-C", stage, "reset", "--hard", head])

    # Fitter seed override. Placement is the only thing it changes, so a
    # sub-nanosecond violation can sometimes be closed by reseeding rather than
    # by restructuring RTL -- worth trying first when the shortfall is within
    # seed-to-seed noise. Patched into the STAGE only; the committed .qsf keeps
    # whatever seed the tree records, so a build stays reproducible from its
    # commit plus this flag.
    if args.seed is not None:
        # The SEED lives in the qsf of the revision being BUILT. Patching
        # Psikyo.qsf while building Psikyo_stp silently changes nothing, and
        # the sweep then reports N identical slacks -- which reads as
        # placement insensitivity rather than as a no-op. That cost an hour
        # of build time on 2026-09-02; hence the revision-derived path and
        # the explicit existence check.
        qsf = os.path.join(stage, "%s.qsf" % args.rev)
        if not os.path.isfile(qsf):
            sys.exit("no %s to patch a SEED into -- does revision %s exist?"
                     % (qsf, args.rev))
        text = open(qsf, encoding="utf-8", errors="replace").read()
        new, n = re.subn(r"(?m)^set_global_assignment -name SEED .*$",
                         "set_global_assignment -name SEED %d" % args.seed, text)
        if n != 1:
            sys.exit("expected exactly one SEED assignment in %s, found %d" % (qsf, n))
        open(qsf, "w", encoding="utf-8", newline="\n").write(new)
        print("seed:   %d (stage only)" % args.seed)

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
    violations = read_slacks(summary)

    if not ok:
        sys.exit("BUILD FAILED -- see %s" % log_path)

    # A debug build may ship with negative slack: it runs on our own hardware,
    # and the instrumented revision carries SignalTap and the tracer, which cost
    # timing we do not intend to pay in a release. A release build may not --
    # once it leaves here we cannot know what it runs on, and a marginal path is
    # exactly the fault that surfaces as someone else's intermittent glitch.
    # See docs/RELEASE_PROCESS.md.
    is_release = not args.rev.endswith("_stp")
    if violations and is_release and not args.allow_negative_slack:
        print("")
        for clk, slack, tns in violations:
            print("  FAILING: %-58s %8.3f  TNS %s" % (clk, slack, tns))
        sys.exit(
            "NOT RELEASE QUALIFIED -- %d clock(s) fail timing.\n"
            "The .rbf is at %s but must not be published.\n"
            "Close timing, rebuild as the debug revision (--rev Psikyo_stp), or\n"
            "pass --allow-negative-slack if you are deliberately publishing a\n"
            "known-marginal build and will say so in the release notes."
            % (len(violations),
               os.path.join(stage, "output_files", "%s.rbf" % args.rev)))

    if violations and is_release:
        print("")
        print("WARNING: --allow-negative-slack given; publishing a build that")
        print("         fails timing on %d clock(s). Say so in the release notes."
              % len(violations))
    elif violations:
        print("(negative slack is qualified for the debug revision; a release")
        print(" build is gated on closing it)")

    print("OK -- deploy with:\n  python scripts/deploy_rbf.py --log \"%s\" "
          "--rbf \"%s\" --name Arcade-Psikyo_NNNNNNNN.rbf"
          % (log_path, os.path.join(stage, "output_files", "%s.rbf" % args.rev)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
