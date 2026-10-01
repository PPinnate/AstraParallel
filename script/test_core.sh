#!/bin/bash
set -euo pipefail
ASTRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || { echo "A full Xcode installation is required: $DEVELOPER_DIR" >&2; exit 1; }
cd "$ASTRA_ROOT"
mkdir -p .build .cache/swiftpm
ASTRA_TEST_DIR="$(mktemp -d "$ASTRA_ROOT/.build/core-tests.XXXXXX")"
trap 'rm -rf "$ASTRA_TEST_DIR"' EXIT
mkdir -p "$ASTRA_TEST_DIR/Sources" "$ASTRA_TEST_DIR/Tests"
cp -R Sources/AstraCore "$ASTRA_TEST_DIR/Sources/"
cp -R Tests/AstraCoreTests "$ASTRA_TEST_DIR/Tests/"
cat > "$ASTRA_TEST_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AstraCoreChecks",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AstraCore"),
        .testTarget(name: "AstraCoreTests", dependencies: ["AstraCore"])
    ]
)
SWIFT
export CLANG_MODULE_CACHE_PATH="$ASTRA_ROOT/.cache/core-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ASTRA_ROOT/.cache/core-swift"
xcrun swift test --disable-sandbox --package-path "$ASTRA_TEST_DIR" \
    --cache-path "$ASTRA_ROOT/.cache/swiftpm"
xcrun clang -std=c11 -Wall -Wextra -Werror \
    -I vendor/CocoaSpice/Sources/CocoaSpice \
    Tests/ScanoutCopyValidityCheck.c -o "$ASTRA_TEST_DIR/ScanoutCopyValidityCheck"
"$ASTRA_TEST_DIR/ScanoutCopyValidityCheck"
PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_runtime_kit.py
