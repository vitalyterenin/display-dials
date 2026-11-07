#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep build caches outside the Documents file provider.
build_dir="${DISPLAY_DIALS_BUILD_DIR:-$HOME/Library/Developer/DisplayDials/Build}"
swift build --scratch-path "$build_dir" --arch arm64
binary_dir="$(swift build --scratch-path "$build_dir" --arch arm64 --show-bin-path)"
"$binary_dir/DisplayDials" --diagnostics
"$binary_dir/DisplayDials" --smoke-test
