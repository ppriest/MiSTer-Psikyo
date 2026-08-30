# Release process

Two Quartus revisions, and they are held to different standards. This is the
procedure for turning a build into something other people run.

| | `Psikyo_stp` (debug) | `Psikyo` (release) |
| --- | --- | --- |
| Built by | `build_staged.py` (default) | `build_staged.py --rev Psikyo` |
| Contains | SignalTap, debug tracer, Debug OSD page | none of it -- compiled out |
| Timing | **may ship with negative slack** | **must close timing** |
| Goes to | our own DE10-nano | `releases/`, other people's hardware |

The asymmetry is the point. A debug build runs on hardware we control and in
front of someone who knows what a marginal path looks like, and the
instrumentation itself costs timing we have no intention of paying in a
release. A release build goes to hardware we cannot see, where a path that
only just fails becomes an intermittent glitch someone else has to chase and
cannot diagnose. So negative slack is qualified for the debug revision and
disqualifying for a release.

`build_staged.py` enforces this rather than leaving it to memory: on a release
revision it reads every clock in the `.sta.summary` -- not just `clk_sys` --
and refuses to print the deploy command if any of them fail, naming the
offenders. `--allow-negative-slack` overrides it, prints a warning instead,
and obliges you to state the shortfall in the release notes. Reach for it
knowingly or not at all.

Steps for a release:

1. `python scripts/build_staged.py --rev Psikyo` -- must pass the timing gate.
2. Smoketest the five parent games (`scripts/smoketest.py`), which loads each
   and captures screenshots.
3. Deploy and play-test; the debug revision is the one to reach for if
   anything needs diagnosing.
4. Publish the `.rbf` and the `.mra` set together under `releases/`. They are
   coupled -- the SDRAM layout and the ROM-load path are both encoded in the
   MRAs, so a mismatched pair fails in ways that look like core bugs.

**Current state: the core does not pass this gate.** Worst setup slack is
-1.117 ns on `clk_sys`, all of it in the OPL4 PCM pipeline. Six successive
splits took it from -6.633 (TNS -2717) to -1.117 (TNS -112) by moving work
into states that were either running in parallel or already stalled on the
sample ROM, so none of them cost a cycle. What remains is the envelope
arithmetic in S_ENV2 -- the attack multiply, clamps, reverb decision and the
24-entry write decode in one clock -- and there is no free state left to hide
it in, so closing it means adding one. That is affordable (~24 cycles of a
~1948-cycle sample budget) but is the first split with a cost. Until it
closes, builds are debug builds.

