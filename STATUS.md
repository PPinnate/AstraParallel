# Astra Parallel status

The published source snapshot is Astra 0.3.0, with reliability and desktop-integration changes implemented on September 27, 2026. Publication documentation and the compact-source tooling were added on October 1, 2026.

The publication export was checked again: all 30 core tests passed, the native copy-recovery model and dependency-kit tamper test passed, and the compact source built a signed standalone preview with the existing pinned kit. Both patch stages reconstructed source matching all 465 DXMT, 581 virglrenderer, and 11,982 Neptune regular files. All three public upstream source downloads matched the pinned hashes. Documentation links and the export's static privacy/file checks passed. The local privacy model's documentation flags were public upstream commit hashes. No VM was started and no guest acceptance gate was closed by these checks.

| Check | Evidence boundary |
|---|---|
| Core regression tests | 30 tests passed for the 0.3.0 host update |
| Native display-copy recovery model | Passed; this is a C model, not a real guest-GPU failure test |
| Runtime-kit integrity checks | Passed tampered, missing, extra, and escaping-input cases |
| Clean GUI/engine build | Passed in a separate source folder using the explicit pinned binary kit |
| Host UI | VM status, stopped resource edits, new-VM dialog, and clipboard preference persistence passed on a fixture |
| Standalone runtime | A 0.2.0 Windows guest booted at 3840×2160 without installed UTM; its accepted graphics runtime is retained by 0.3.0 |
| New-VM installer boot | Reached the Windows ARM Setup language screen with independent disk, firmware, TPM, and UUID |
| Full fresh Windows and guest-tools installation | Pending |
| 0.3.0 real guest clipboard/shutdown/input/audio/game regression | Pending |
| Another physical Mac | Not tested |
| Full accepted renderer/worker/guest-driver source rebuild | Not demonstrated |
| Public app download and notarization | Not provided by this source publication |

The new host code separates QMP and QGA communication, supervises graceful shutdown, cancels stale queued input, bounds the key queue, provides opt-in text clipboard, and exposes VM/service health and stopped resource settings. Accepted native graphics and guest-driver binaries were retained, not rebuilt.

The main remaining work is a qualified full source rebuild, a clean Windows installation and regression run, guest-tools repair/upgrade/uninstall, guest lifecycle fault tests, GPU synchronization tests, and second-Mac distribution validation. Shared folders, checkpoints, image/file clipboard, multiple active VMs, microphone/camera/gamepad passthrough, and seamless guest windows are not implemented.

Successful source reconstruction and host tests do not prove audible Windows sound, correct game camera movement, graphics conformance, FPS, or end-to-end Windows recovery. No new performance measurement is claimed.
