#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep build caches outside the Documents file provider.
build_dir="${DISPLAY_DIALS_BUILD_DIR:-$HOME/Library/Developer/DisplayDials/Build}"
swift build --scratch-path "$build_dir" --arch arm64
# Newer Command Line Tools keep Testing macros in a separate plugin directory.
# Pass it explicitly when present; Xcode toolchains normally discover it directly.
test_args=(--scratch-path "$build_dir" --arch arm64 --disable-xctest)
testing_plugin="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
    test_args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test "${test_args[@]}"
binary_dir="$(swift build --scratch-path "$build_dir" --arch arm64 --show-bin-path)"
"$binary_dir/DisplayDials" --diagnostics
"$binary_dir/DisplayDials" --smoke-test

# Verify that growing menus escape the small popover and keep a screen-space anchor.
xcrun swiftc Sources/DisplayDials/OptionsMenuPresentation.swift Tests/MenuPresentationTests.swift \
    -o "$build_dir/menu-presentation-tests"
"$build_dir/menu-presentation-tests"

# Inspect real menu/row frames while a status-item popover is open (no AX permission needed).
xcrun swiftc Sources/DisplayDials/OptionsMenuPresentation.swift Tests/MenuLayoutIntegration.swift \
    -o "$build_dir/menu-layout-integration"
"$build_dir/menu-layout-integration"

# Verify immediate tick actions while mouse tracking is still active, without OS writes.
xcrun swiftc Sources/DisplayDials/WarmthSlider.swift Tests/WarmthSliderTests.swift \
    -o "$build_dir/warmth-slider-tests"
"$build_dir/warmth-slider-tests"
