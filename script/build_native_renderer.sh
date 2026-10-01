#!/bin/bash
set -euo pipefail
ASTRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASTRA_RENDERER="$ASTRA_ROOT/artifacts/renderer-build"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PYTHONPATH="$ASTRA_RENDERER/build-tools"
export CLANG_MODULE_CACHE_PATH="$ASTRA_ROOT/.cache/renderer-clang"
export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
ASTRA_LLVM="$ASTRA_RENDERER/toolchains/llvm@15/15.0.7"
ASTRA_BUILD="$ASTRA_RENDERER/build-so-only-v1"
ASTRA_ZSTD="$ASTRA_RENDERER/toolchains/zstd/libzstd.a"
test -f "$ASTRA_LLVM/include/llvm/Config/llvm-config.h"
test -f "$ASTRA_ZSTD"
xcrun --no-cache -sdk macosx metal --version
if [[ ! -f "$ASTRA_BUILD/meson-private/coredata.dat" ]]; then
    python3 -m mesonbuild.mesonmain setup "$ASTRA_BUILD" "$ASTRA_RENDERER/dxmt-src" \
        --buildtype=release --wrap-mode=nodownload \
        -Dnative_llvm_path="$ASTRA_LLVM" -Denable_tests=false -Dcpp_link_args="$ASTRA_ZSTD"
else
    python3 -m mesonbuild.mesonmain configure "$ASTRA_BUILD" -Dcpp_link_args="$ASTRA_ZSTD"
fi
python3 -m mesonbuild.mesonmain compile -C "$ASTRA_BUILD" -j 6 dxmt-native
