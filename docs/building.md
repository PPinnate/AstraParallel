# Develop and build Astra

## Source requirements

Use Apple Silicon, macOS 14 or newer, full Xcode at `/Applications/Xcode.app/Contents/Developer` or a valid `DEVELOPER_DIR` override, Python 3.11 or newer, and Git. Source retrieval uses public upstream downloads; no paid cloud service, advertising, hosted runner, or subscription is configured.

Clone the repository and run:

```sh
./script/test_core.sh
```

This copies only AstraCore and its tests into a temporary package under `.build`, runs Swift tests, compiles and runs the small C scanout-copy recovery test, and runs Python dependency-kit integrity tests. It does not link the GUI's SPICE frameworks or boot Windows. Runtime outputs stay ignored locally.

## Rebuild the interface and VM engine

The complete build needs the exact accepted binary kit. Its manifest pin is in `script/runtime-kit.lock.json`. The kit supplies compatible QEMU/SPICE/support frameworks, custom native graphics and render worker, precompiled shaders, ARM firmware, guest-tools media, and app metadata. **No public kit download is supplied by this repository.** Generic upstream downloads do not reproduce these custom inputs.

If you already have that kit:

```sh
python3 script/runtime_kit.py --verify /absolute/path/to/accepted-20260925
./script/build_and_run.sh --stage-ui --runtime-kit /absolute/path/to/accepted-20260925
```

Open the complete resulting app under `dist/standalone/<timestamp>/` when ready. The staging command itself starts no VM and leaves existing apps and machines alone. The full build copies the pinned graphics inputs, builds the Swift interface and native engine, applies local ad hoc signatures, and verifies bundle-relative dependencies.

The existing `runtime_kit.py --export-app APP --destination NEW_DIRECTORY` helper can export inputs from an accepted app. It refuses an output that differs from the committed pin; do not change the pin merely to bypass verification. The GUI and engine build passed with explicit binary inputs on the development Mac. This is not a source-only rebuild of the graphics drivers or QEMU.

`--build-only` promotes a built app to `dist/Astra Parallel.app` and requires that app and its helpers to be closed. Use `--stage-ui` during normal development. No routine build should restart, reset, delete, or resize a VM.

## Modify the core

- VM planning, resource validation, and state: `Sources/AstraCore`.
- QMP/QGA protocols and socket deadlines: `Sources/AstraCore`.
- Interface, session supervision, clipboard, and input: `Sources/AstraParallel`.
- Native QEMU engine: `Sources/AstraEngine/main.m`.
- GLib polling adapter: `Sources/AstraPlatform`.
- SPICE display/audio/input integration: `vendor/CocoaSpice`.

Keep graceful shutdown separate from confirmed forced power-off. Keep clipboard sharing off by default, bounded, per VM, and foreground-only. Preserve disk/firmware/TPM/UUID together. Test protocol and input changes with the host suite, then perform a real Windows regression before claiming guest behavior.

## Graphics and guest media

Fetch pinned source using `python3 script/fetch_graphics_sources.py --state baseline`. See [graphics.md](graphics.md) for the experimental state and reconstruction checks. Native/guest rebuilds need additional LLVM, Meson, Metal, compatible framework inputs, and a Windows ARM compiler/WDK environment. Historical recipes are included for reference but are not a turnkey toolchain installer.

`guest_install_astra_tools.ps1` is the guest installer source. `build_guest_tools_media.py` expects a separately supplied verified payload at `artifacts/guest-tools/payload`, including its payload manifest. The public [payload hash record](guest-tools-payload.json) contains no driver binaries. Packaging or testing a new guest-tools image is a separate qualification task.

All original component licenses and notices must accompany modified source. Inspect [upstream-notices.md](upstream-notices.md) before redistribution. The source preview does not establish public binary-release readiness.
