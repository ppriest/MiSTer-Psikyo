#!/usr/bin/env bash
# Build one revision across several fitter seeds and report the spread.
#
# Placement variance on this design is large -- logically trivial edits have
# moved worst-case slack across a 1.3ns band and relocated the bottleneck
# between subsystems. That makes single-build comparisons worthless for
# attribution, and it makes "did my change help?" unanswerable from one build.
# Sweeping seeds gives a distribution instead: pick the best bitstream, and
# see whether the design closes at ANY seed before restructuring more RTL.
set -u
REV="${REV:-Psikyo}"
SEEDS="${SEEDS:-1 2 3 4 5}"
OUT=build_keep/seed_sweep_$(date +%H%M).txt
: > "$OUT"
for s in $SEEDS; do
    echo "=== seed $s ===" | tee -a "$OUT"
    # Capture to a file rather than piping straight into grep: a pipeline
    # discards build_staged.py's exit status, and this loop then treated a
    # CRASHED build exactly like a good one -- it copied the PREVIOUS seed's
    # .rbf under this seed's name and reported the previous seed's slack as
    # this seed's result. Quartus 17.0 dies in the fitter with an access
    # violation often enough for that to matter (seed 2 on 2026-09-02), and
    # two seeds showing identical slack reads as a placement-insensitive
    # design rather than as a missing build -- the same stale-artefact trap
    # deploy_rbf.py exists to prevent.
    python scripts/build_staged.py --rev "$REV" --seed "$s" --allow-dirty \
        > build_keep/.sweep_last_stdout 2>&1
    rc=$?
    grep -E "worst clk_sys|FAILING|NOT RELEASE QUALIFIED|OK -- deploy" \
        build_keep/.sweep_last_stdout | tee -a "$OUT"
    # Quartus's own success line is the ONLY test for "did this build
    # happen". Do NOT use rc: build_staged.py also returns 1 for a build
    # that compiled perfectly and merely failed the RELEASE timing gate,
    # and treating that as a crash threw away all five bitstreams and
    # logs of a release sweep -- including the best one, 14ps short,
    # whose failing path then could not be examined without rebuilding.
    if ! grep -q "Full Compilation was successful" build/q_staged.log 2>/dev/null; then
        echo "  *** BUILD FAILED (rc=$rc) -- NO RESULT for seed $s, nothing kept ***" | tee -a "$OUT"
        grep -m2 -E "Fatal Error|^Error " build/q_staged.log 2>/dev/null | sed "s/^/      /" | tee -a "$OUT"
        continue
    fi
    if [ -f "build/output_files/$REV.rbf" ]; then
        cp -p "build/output_files/$REV.rbf" "build_keep/${REV}-seed${s}.rbf"
        cp -p build/q_staged.log "build_keep/${REV}-seed${s}.buildlog"
        # Resource figures too: the stage rewrites .fit.summary on every
        # seed, so without this the numbers for any build but the last one
        # are gone by the time the sweep ends.
        cp -p "build/output_files/$REV.fit.summary" "build_keep/${REV}-seed${s}.fit.summary" 2>/dev/null || true
    fi
done
echo "=== summary ===" | tee -a "$OUT"
grep -H "worst clk_sys" "$OUT" | tee -a "$OUT"
