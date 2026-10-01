# Astra Parallel source maintenance

Read README.md, STATUS.md, docs/building.md, docs/installation.md, docs/graphics.md, and docs/upstream-notices.md before changing the project.

This repository contains the macOS VM implementation. Keep separate mobile applications, VM state, personal data, diagnostic logs, compiled runtime packages, and signing credentials out of it. Preserve legal notices in vendored source and patches.

Use `./script/test_core.sh` for runtime-independent host tests. Use `./script/build_and_run.sh --stage-ui --runtime-kit PATH` for an app preview when the exact pinned kit is available. Routine changes must not boot, stop, reset, resize, delete, or replace another VM or app as a side effect.

Keep clipboard sharing opt-in and scoped to the selected VM and foreground app. Ordinary shutdown must never silently become a hard power cut. Keep each machine's UUID, disk, firmware variables, and TPM state together. Never change game/launcher files or anti-cheat/security settings as part of VM work.

Graphics source reconstruction is separate from binary qualification. Baseline patches reconstruct recorded source; development patches add unshipped experiments. A host test, protocol acknowledgment, or source hash check does not prove live Windows audio, input, graphics conformance, recovery, or FPS.

Use full Xcode. Keep scripts beside their imported helpers because they derive the project root from their parent directory. Do not install toolchains or alter runtime pins for documentation changes. Run the source publication check and inspect the actual upload list before sharing changes.
