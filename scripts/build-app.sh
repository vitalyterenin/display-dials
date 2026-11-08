#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep build caches outside the Documents file provider.
build_dir="${DISPLAY_DIALS_BUILD_DIR:-$HOME/Library/Developer/DisplayDials/Build}"
build_args=(--scratch-path "$build_dir" -c release --arch arm64)
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
# Keep the signed bundle outside Documents: its file provider adds FinderInfo
# again after signing and invalidates the bundle signature.
output_dir="${DISPLAY_DIALS_OUTPUT_DIR:-$HOME/Library/Developer/DisplayDials}"
mkdir -p "$output_dir"
staging="$(mktemp -d "$output_dir/.display-dials-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app_dir="$staging/Display Dials.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"
cp "$binary_dir/DisplayDials" "$app_dir/Contents/MacOS/DisplayDials"
framework="$(python3 - "$build_dir" <<'PY'
import pathlib,sys
matches=list(pathlib.Path(sys.argv[1], 'artifacts').glob('**/macos-*/Sparkle.framework'))
if len(matches)!=1: raise SystemExit(f'Expected one Sparkle framework, found {len(matches)}')
print(matches[0])
PY
)"
ditto "$framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
# This app is not sandboxed, so these optional Sparkle services are unused.
rm -rf "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
sparkle="$app_dir/Contents/Frameworks/Sparkle.framework"
# Ship only Apple Silicon slices, including Sparkle's prebuilt helper tools.
for executable in "$sparkle/Versions/B/Sparkle" "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    if [[ "$(lipo -archs "$executable")" != arm64 ]]; then
        lipo "$executable" -thin arm64 -output "$executable.arm64"
        mv "$executable.arm64" "$executable"
    fi
done
python3 scripts/release.py plist "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
cp Resources/PrivacyInfo.xcprivacy "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy"
python3 scripts/licenses.py install --app "$app_dir" \
    --sparkle-license "$build_dir/checkouts/Sparkle/LICENSE"
# Compile all standard and Retina icon sizes from the approved transparent source.
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$app_dir/Contents/Resources/AppIcon.icns"
# Finder / file providers may add this attribute to an existing generated bundle.
# Remove only Finder metadata; do not remove quarantine or other security metadata.
xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
# Developer ID can later replace ad hoc signing in this build stage.
identity="${DISPLAY_DIALS_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$sparkle/Versions/B/Autoupdate"
codesign "${sign_args[@]}" "$sparkle/Versions/B/Updater.app"
codesign "${sign_args[@]}" "$sparkle"
codesign "${sign_args[@]}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
destination="$output_dir/Display Dials.app"
if [[ -e "$destination" ]]; then rm -rf "$destination"; fi
mv "$app_dir" "$destination"
printf 'Built: %s\n' "$destination"
