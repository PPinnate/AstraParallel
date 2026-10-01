# Upstream notices

Original Astra code is covered by the root MIT license only as scoped there. Third-party code and derived patches retain upstream license and copyright notices; the root license does not relicense them.

## UTM origin and component credit

Astra uses work from the [UTM project and contributors](https://github.com/utmapp/UTM). The original accepted runtime import was UTM 5.0.5 (124), and `Sources/AstraEngine/main.m` uses the compatible QEMU embedding entry points. The build recipe checks that initial import version, and the retained runtime manifest records that origin. Bundling the runtime allows Astra to run independently of an installed UTM app while retaining this provenance.

The modified CocoaSpice viewer is direct source reuse: its original `osy` copyright and Apache-2.0 headers remain in the files. Comparison with the pinned upstream tree found 652 byte-identical files, 12 modified upstream files including its README/package manifest, and three added Astra files. These counts describe the CocoaSpice component at that revision; binary distribution checks are recorded below.

Credit the DXMT authors and CodeWeavers as well as UTM's compatible fork/build work; the retained DXMT license explicitly records that authorship. Credit virglrenderer and Mesa contributors for the render-worker and Neptune/Triton driver sources. QEMU, SPICE, GLib/GStreamer, swtpm, firmware and other runtime projects retain their own component licenses.

## Astra modifications to CocoaSpice

Modified upstream files carry a `Modified for Astra Parallel` source notice while retaining their original copyright/license headers. The modified README identifies the package as Astra's modified viewer. The added `CSAudioPlayback.m`, `CSAudioPlayback.h` and `CSCopyValidity.h` supply the audio playback and display-copy recovery support.

| Modified file | Local work |
|---|---|
| `Package.swift` | Command-line build support and shader source resource |
| `CSConnection.m` / `include/CSConnection.h` | Audio playback integration, connection controls and desktop-integration APIs |
| `CSSession.m` | Bounded opt-in clipboard handling and guest-agent integration |
| `CSDisplay.m` / `include/CSDisplay.h` | Presentation/copy-recovery and display timing support |
| `CSCursor.m` / `include/CSCursor.h` | Cursor ownership/visibility and native cursor integration |
| `gst_ios_init.m` | Shared initializer's macOS path and plugin/environment handling |
| `CocoaSpiceRenderer/CSMetalRenderer.m` / `CocoaSpiceRenderer/include/CSMetalRenderer.h` | Metal presentation scheduling and timing controls |

Viewer paths in this table are relative to `vendor/CocoaSpice/Sources/CocoaSpice`; renderer paths are relative to `vendor/CocoaSpice/Sources`, and the package manifest is at `vendor/CocoaSpice/Package.swift`. The shared initializer supports macOS; no separate iOS app is included. Prominent change notices follow the modified-file notice in [Apache-2.0 section 4](https://github.com/utmapp/CocoaSpice/blob/127033fa3e59cd49678f49ed54f8adfc060afb56/LICENSE). Existing licenses and notices are preserved.

## Pinned sources and licenses

- Modified CocoaSpice is based on `utmapp/CocoaSpice` revision `127033fa3e59cd49678f49ed54f8adfc060afb56`, selected by UTM 5.0.5. Its Apache-2.0 license is at `vendor/CocoaSpice/LICENSE`. Bundled dependency headers retain their own notices. Shared conditional platform code remains intact where it also supports macOS; no separate iOS application is included.
- DXMT is pinned to `utmapp/dxmt` revision `bcdcf6da89af6c9fedeb2fc92b4367b23d5d6ed6`. This revision is **LGPL-2.1-or-later**, not the MIT license of older releases. Its notices identify Feifan He for CodeWeavers. `third-party-licenses/dxmt` retains `LICENSE`, `COPYING.LIB`, and the historical license notice. DXMT patches, derived files, and any supplied third-party headers keep their original terms.
- virglrenderer is pinned to `482f9d8b8c2d2288efa10a027116216909d2c226`. Its notice is retained at `third-party-licenses/virglrenderer/COPYING` and accompanies the downloaded source.
- Neptune/Mesa is pinned to `osy/virtio-win-mesa` revision `9af316b3d8690c6f8a3026e4e88bd8035362d0b1`. Mesa uses several component licenses; retain per-file notices and the upstream license overview at `third-party-licenses/neptune/docs/license.rst`.
- QEMU, SPICE, GLib/GStreamer, swtpm, EDK II, MoltenVK, and supporting runtime components originate from their respective upstream projects. The accepted runtime import used UTM 5.0.5 (124), including QEMU `10.0.12-utm`. These compiled dependencies are not included in this source repository. The compatible runtime and custom graphics binaries remain separate required build inputs.
- No Parallels implementation, D3DMetal binary, Windows image, game asset, installer, Microsoft build toolchain, or guest-driver binary is uploaded in this repository.

For a future binary release, complete the corresponding-source, notice, relinking/replacement, dependency-license, signing, and distribution checks for every shipped component. Publishing these source patches does not itself qualify a public binary distribution. Keep upstream notices with modified copies.
