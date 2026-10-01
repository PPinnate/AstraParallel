# Upstream notices

Original Astra code is covered by the root MIT license only as scoped there. Third-party code and derived patches retain upstream license and copyright notices; the root license does not relicense them.

- Modified CocoaSpice is based on `utmapp/CocoaSpice` revision `127033fa3e59cd49678f49ed54f8adfc060afb56`, selected by UTM 5.0.5. Its Apache-2.0 license is at `vendor/CocoaSpice/LICENSE`. Bundled dependency headers retain their own notices. Shared conditional platform code remains intact where it also supports macOS; no separate iOS application is included.
- DXMT is pinned to `utmapp/dxmt` revision `bcdcf6da89af6c9fedeb2fc92b4367b23d5d6ed6`. This revision is **LGPL-2.1-or-later**, not the MIT license of older releases. Its notices identify Feifan He for CodeWeavers. `third-party-licenses/dxmt` retains `LICENSE`, `COPYING.LIB`, and the historical license notice. DXMT patches, derived files, and any supplied third-party headers keep their original terms.
- virglrenderer is pinned to `482f9d8b8c2d2288efa10a027116216909d2c226`. Its notice is retained at `third-party-licenses/virglrenderer/COPYING` and accompanies the downloaded source.
- Neptune/Mesa is pinned to `osy/virtio-win-mesa` revision `9af316b3d8690c6f8a3026e4e88bd8035362d0b1`. Mesa uses several component licenses; retain per-file notices and the upstream license overview at `third-party-licenses/neptune/docs/license.rst`.
- QEMU, SPICE, GLib/GStreamer, swtpm, EDK II, MoltenVK, and supporting runtime components originate from their respective upstream projects. The accepted runtime import used UTM 5.0.5 (124), including QEMU `10.0.12-utm`. These compiled dependencies are not included in this source repository. The compatible runtime and custom graphics binaries remain separate required build inputs.
- No Parallels implementation, D3DMetal binary, Windows image, game asset, installer, Microsoft build toolchain, or guest-driver binary is uploaded in this repository.

For a future binary release, complete the corresponding-source, notice, relinking/replacement, dependency-license, signing, and distribution checks for every shipped component. Publishing these source patches does not itself qualify a public binary distribution. Keep upstream notices with modified copies.
