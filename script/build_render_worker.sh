#!/bin/bash
set -euo pipefail
ASTRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASTRA_RENDERER="$ASTRA_ROOT/artifacts/renderer-build"
ASTRA_SOURCE="$ASTRA_RENDERER/virgl-src"
ASTRA_BUILD="${ASTRA_WORKER_BUILD_DIR:-$ASTRA_RENDERER/build-worker-v1}"
ASTRA_PKGCONFIG="$ASTRA_RENDERER/pkgconfig"
export DEVELOPER_DIR="${ASTRA_XCODE_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export PYTHONPATH="$ASTRA_RENDERER/build-tools"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
export OBJC="$CC"
if [[ ! -d "$ASTRA_SOURCE" ]]; then
    cp -R "$ASTRA_ROOT/artifacts/reference/virglrenderer-482f9d8b8c2d2288efa10a027116216909d2c226" "$ASTRA_SOURCE"
fi
mkdir -p "$ASTRA_PKGCONFIG"
cat > "$ASTRA_PKGCONFIG/epoxy.pc" <<'PC'
Name: epoxy
Description: Installed libepoxy headers with UTM's existing macOS framework
Version: 1.5.10
Cflags: -I/opt/homebrew/opt/libepoxy/include
Libs: -F/Applications/UTM.app/Contents/Frameworks -framework epoxy.0 -Wl,-rpath,/Applications/UTM.app/Contents/Frameworks
PC
if [[ ! -f "$ASTRA_BUILD/meson-private/coredata.dat" ]]; then
    python3 -m mesonbuild.mesonmain setup "$ASTRA_BUILD" "$ASTRA_SOURCE" \
        --buildtype=release --wrap-mode=nodownload --pkg-config-path="$ASTRA_PKGCONFIG" \
        -Dplatforms=[] -Dneptune=true -Dvenus=true -Dvtest=false -Dtests=false \
        -Drender-server-mode=process -Drender-server-worker=process \
        -Dc_args=-I/opt/homebrew/include
fi
python3 -m mesonbuild.mesonmain compile -C "$ASTRA_BUILD" -j 6 virgl_render_server
