# Tooling

This document describes the build, deploy and verification scripts in this
directory, and the credentials and debugging entry points they depend on.

Hardware iteration is automated; see `../docs/LESSONS_LEARNED.md` for why each of these exists.

| script | purpose |
| - | - |
| `build_staged.py` | build a git-worktree snapshot of HEAD in `../build/` (gitignored), so the main tree stays editable mid-build; the log, `output_files/` and a `BUILT_COMMIT` stamp land under `../build/`. Default revision is the instrumented `Psikyo_stp` (fitter SEED pinned at 7 - the default-seed fit did not boot); `-rev Psikyo` for release. Release builds are gated on timing -- see [../docs/RELEASE_PROCESS.md](../docs/RELEASE_PROCESS.md) |
| `mister_hw_test.py` | deploy a `.rbf`, launch a `.mra`, pull a screenshot |
| `deploy_rbf.py` | deploy only if the build actually succeeded |
| `deploy_mra.py` | validate an `.mra`, then copy it |
| `validate_mra.py` | check `.mra` well-formedness and structure |
| `verify_rom_trace.py` | solve a ROM interleave against a hardware trace |
| `decode_trace.py` | decode a debug-overlay capture, saved per settings |
| `decode_vram.py` | extract tilemap VRAM and video registers from a capture |
| `png_census.py` | colour census of a screenshot |

Credentials are read from `../mister.env` (gitignored).

For the debug overlay, the JTAG probes and when to reach for video capture
instead of a screenshot, see
[../docs/DEBUGGING_ON_HARDWARE.md](../docs/DEBUGGING_ON_HARDWARE.md).
