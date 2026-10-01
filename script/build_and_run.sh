#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || { echo "A full Xcode installation is required: $DEVELOPER_DIR" >&2; exit 1; }
# Stage a complete private runtime, retaining the verified renderer and shaders.
# --stage-ui / --standalone do not replace the canonical app or touch a live VM.
exec python3 script/build_standalone.py --mode="$MODE" "$@"
