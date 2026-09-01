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
    python scripts/build_staged.py --rev "$REV" --seed "$s" --allow-dirty 2>&1 \
        | grep -E "worst clk_sys|FAILING|NOT RELEASE QUALIFIED|OK -- deploy" | tee -a "$OUT"
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
