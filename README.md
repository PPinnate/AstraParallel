# Astra Parallel

Astra Parallel is a macOS app for running Windows 11 ARM virtual machines on Apple Silicon. It combines a SwiftUI/AppKit interface, QEMU with Apple's Hypervisor framework, a SPICE viewer, and a modified Direct3D-to-Metal graphics path.

**Current source: 0.3.0. This is an experimental developer preview.** Host tests passed on the development Mac. A complete fresh Windows installation, guest-tools installation, game regression test, and second physical Mac remain unverified. This repository does not claim Parallels performance parity.

## Credits and upstream work

Astra Parallel builds on the open-source work of [UTM](https://github.com/utmapp/UTM) and its contributors. Its accepted runtime was originally imported from **UTM 5.0.5 (124)**. The source includes a modified [CocoaSpice](https://github.com/utmapp/CocoaSpice) viewer and patches based on UTM's [DXMT](https://github.com/utmapp/dxmt) and [virglrenderer](https://github.com/utmapp/virglrenderer) forks and the [Neptune/Triton Mesa driver](https://github.com/osy/virtio-win-mesa).

Credit also goes to the upstream QEMU, SPICE, DXMT authors and CodeWeavers, virglrenderer, Mesa, and other dependency contributors. Astra's macOS interface and integration work use these components in a standalone bundle that runs independently of an installed UTM app.

Original copyright notices and component licenses remain with the source. The root MIT license covers only the original Astra files as scoped in [LICENSE](LICENSE); third-party and derived code keeps its own terms. See [upstream credits, exact source pins, and modification notes](docs/upstream-notices.md).

## What you can do here

- Read and modify the macOS interface, VM lifecycle, guest-agent protocols, audio playback, input capture, and opt-in text clipboard.
- Run the core regression tests without a Windows VM or binary runtime kit.
- Rebuild the interface and engine if you already have the exact pinned runtime kit.
- Fetch pinned graphics source and apply the included modifications with a script.

The repository contains source, tests, small dependency headers, graphics patches, and documentation. VM images, Windows installers, app/runtime/driver binaries, build toolchains, personal files, credentials, and captured diagnostic logs are excluded. There is no separate iOS app in this repository.

## Get the source and run tests

Use an Apple Silicon Mac with macOS 14 or newer, full Xcode, and Python 3.11 or newer:

```sh
git clone https://github.com/PPinnate/AstraParallel.git
cd AstraParallel
./script/test_core.sh
```

The test script builds a temporary package containing only AstraCore and its tests, checks the native display-copy recovery model, and runs dependency-kit tamper tests. It starts no VM and needs no downloaded runtime. See [development and build instructions](docs/building.md).

## Install and create a Windows VM

**This source repository does not currently provide an app installer or a public runtime-kit download.** A clone alone cannot build the complete app: the accepted custom graphics binaries, compatible frameworks, firmware, shaders, and guest-tools image are still required. Do not substitute an arbitrary QEMU or UTM release for the pinned kit.

If you already have an accepted complete `Astra Parallel.app`, copy the entire bundle to your Applications folder and follow the [installation and Windows setup guide](docs/installation.md). UTM, Homebrew, and Xcode are not required to run that app. The current local build is ad hoc signed, and public notarized distribution remains pending.

If you have the pinned kit, build a separate app from this source:

```sh
./script/build_and_run.sh --stage-ui --runtime-kit /absolute/path/to/accepted-20260925
```

The result appears under `dist/standalone/<timestamp>/Astra Parallel.app`. This command builds a preview and starts no VM. [Build inputs and remaining work](docs/building.md) explain exactly what is and is not reproducible.

## Graphics source without a large checkout

```sh
python3 script/fetch_graphics_sources.py --state baseline
```

This downloads the three pinned upstream source archives, checks their SHA-256 hashes, and applies the recorded baseline patches. It does not download an app, install a toolchain, or compile or deploy a renderer. An explicit `--state development` adds the later unshipped experiments. See [graphics source and qualification](docs/graphics.md) before changing these components.

## Controls

| Action | Control |
|---|---|
| Create or open a VM | New Windows VM… / Open Existing VM… |
| Inspect VM and guest-service health | Virtual Machine → VM Status…; Command–Shift–I |
| Change CPU/RAM/name | VM Settings… while Windows is stopped |
| Capture mouse for games | Command–Shift–M |
| Release capture | Control–Option; switching away also releases it |
| Fullscreen | Control–Command–F |
| Volume and background mute | Speaker button / Audio menu |
| Plain-text clipboard | Share Text Clipboard; off by default, per VM, foreground only |
| Normal shutdown | Shut Down; timeout never silently forces power off |

## Project map and status

`Sources/AstraParallel` contains the interface and session management; `Sources/AstraCore` contains VM configuration and control protocols; `Sources/AstraEngine` contains the native engine; `Sources/AstraPlatform` contains the polling adapter. `vendor/CocoaSpice` is the modified viewer and its required headers. Graphics changes live in `patches/graphics`, with pins and reconstruction records in `script/graphics-sources.lock.json`.

- [Measured status and open acceptance gates](STATUS.md)
- [Architecture](docs/architecture.md)
- [Build instructions](docs/building.md)
- [Windows setup](docs/installation.md)
- [Graphics source](docs/graphics.md)
- [Upstream notices and component licenses](docs/upstream-notices.md)
- [Contributing](CONTRIBUTING.md)

Original Astra source is MIT licensed as scoped in [LICENSE](LICENSE). Third-party code, headers, and patches retain their respective upstream licenses. Issue reports should describe the problem and steps to reproduce it without including credentials, clipboard contents, VM data, or unreviewed logs.
