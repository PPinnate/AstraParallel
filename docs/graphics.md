# Graphics source and qualification

The repository keeps the host app small by storing graphics modifications as patches instead of duplicating complete upstream source trees. Source pins, source-archive hashes, patch hashes, and modified-file hashes are in `script/graphics-sources.lock.json`.

| Component | Pinned upstream source | Role |
|---|---|---|
| DXMT | `utmapp/dxmt` at `bcdcf6da89af6c9fedeb2fc92b4367b23d5d6ed6` | Native Direct3D-to-Metal renderer/compiler |
| virglrenderer | `utmapp/virglrenderer` at `482f9d8b8c2d2288efa10a027116216909d2c226` | Host render worker and Neptune transport |
| Neptune | `osy/virtio-win-mesa` at `9af316b3d8690c6f8a3026e4e88bd8035362d0b1` | Windows ARM64/ARM64EC driver and Mesa source |

## Reconstruct source

```sh
python3 script/fetch_graphics_sources.py --state baseline
```

This obtains source archives from the listed upstream projects, verifies their hashes, extracts into new temporary folders, applies the baseline patches, and checks the modified-file hashes. It refuses to overwrite any existing component tree. No compiler, VM, app, or driver is installed or run.

For the later development experiments, choose a separate workspace and run:

```sh
python3 script/fetch_graphics_sources.py --state development
```

The development state adds the DXMT staging-offset experiment, host SHM lifetime/pinning work, and guest paired-unmap synchronization. They were not deployed in the accepted binary package. The baseline overlays and `vendor/graphics/source-state.json` retain the original ten-file comparison. The guest resource-conversion callback correction remains in the baseline.

Downloaded component trees stay ignored. Use `--component dxmt`, `--component virglrenderer`, or `--component neptune` to reconstruct one component. `--offline-archives /path/to/archives` uses already downloaded files with the exact recorded archive names and hashes. A changed archive fails verification instead of being accepted silently.

## Limits

The baseline is recorded source reconstructed by reversing identified later experiments. It does not prove a bit-identical rebuild of the accepted graphics binaries. Native graphics rebuilds and Windows ARM64/ARM64EC guest-driver rebuilds require additional toolchains and qualification.

The retained recipes `build_native_renderer.sh`, `build_render_worker.sh`, and `guest_build_neptune.cmd` describe historical build layouts and extra inputs. Some still reference the historical UTM-compatible framework build environment. They are reference recipes, not routine GUI build commands or a claim that installed UTM is needed to run Astra.

Before deploying a rebuilt candidate, verify component licenses, shader and ABI compatibility, resource-copy/format/depth/Map/Unmap/synchronization controls, real Windows shutdown/restart, audio/input, and the intended applications. Preserve the accepted package until the candidate passes. No captured game assets or diagnostic logs are distributed here.
