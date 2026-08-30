# Debugging on hardware

How to get internal state out of a running core: the video-overlay tracer, the
JTAG probes, and which of the two to reach for.

The core carries an optional debug overlay that drives internal state onto the video
output, decoded by the scripts in `scripts/`, listed in the README's Tooling table. It is enabled from the OSD's Debug page - visible
only on instrumented (`Psikyo_stp`) builds: every Debug-page line in the CONF_STR carries
an `H1` prefix, and `status_menumask` bit 1 tracks the `DEBUG_ISSP` macro, so release
builds hide the page. The tracer itself (trace buffers, overlay dump bands) also compiles
out of release builds entirely (`DEBUG_TRACER_EN` tracks the same macro, reclaiming the
BRAM); the non-tracer debug bits (render disable, sprite swap, Sound IRQ, C00008) stay
functional in a release build if set via the `.CFG`. The overlay can dump
tilemap VRAM, the video registers, and a CPU ROM-read trace without rebuilding. It was
built because there was no JTAG on this setup; `docs/LESSONS_LEARNED.md` explains how to
use it without fooling yourself.

JTAG is supported, which makes SignalTap, In-System Sources and Probes, and the
In-System Memory Content Editor usable. Instrumented (`Psikyo_stp`) builds carry a
handful of purpose-built ISSP probes for specific investigations: a tilemap VRAM
write/poke probe (instance `"W"`, `scripts/write_vram1.tcl`) and a spriteram read probe
(instance `"S"`, `scripts/read_spriteram.tcl`), which root-caused the (now fixed)
sprite-vs-tilemap priority bug. A USB video capture device is also available; it is
the right tool for anything temporal (game speed under load, one-frame flashes, flicker),
where the one-shot API screenshots cannot help. Use capture for temporal questions and API
screenshots for pixel-exact ones, since HDMI output is scaled.
