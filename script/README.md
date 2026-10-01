# Source scripts

| Script | Purpose |
|---|---|
| `test_core.sh` | Host core, native copy-recovery, and dependency-kit tests without a VM/runtime kit |
| `check_public_source.py` | Static source-publication privacy and file-type check |
| `fetch_graphics_sources.py` | Retrieve pinned graphics source, check hashes, and apply baseline or experimental patches |
| `build_and_run.sh` / `build_standalone.py` | Build a standalone preview from the pinned binary kit |
| `runtime_kit.py` | Export/verify accepted binary build inputs against the lock |
| `release_manifest.py` | Record source/component/toolchain identity in a built app |
| `sign_engine.py` | Apply a local ad hoc engine signature; no private signing key is included |
| `stop_idle_app.py` | Refuse app replacement while its GUI/helpers are open |
| `guest_install_astra_tools.ps1` | Guest installer source for a separately supplied verified payload |
| `build_guest_tools_media.py` | Package that payload into a local tools ISO |
| Native/guest build recipes | Historical reference requiring extra restored toolchains and qualification |

Scripts derive the project root from their parent directory and import adjacent helpers. Preserve their layout. See [building.md](../docs/building.md) for supported commands and current input limits.
