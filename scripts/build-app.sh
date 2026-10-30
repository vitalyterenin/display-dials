#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
# Keep the signed bundle outside Documents: its file provider adds FinderInfo
# again after signing and invalidates the bundle signature.
output_dir="${DISPLAY_DIALS_OUTPUT_DIR:-$HOME/Library/Developer/DisplayDials}"
app_dir="$output_dir/Display Dials.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/DisplayDials" "$app_dir/Contents/MacOS/DisplayDials"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Display Dials</string>
<key>CFBundleDisplayName</key><string>Display Dials</string>
<key>CFBundleIdentifier</key><string>com.vitalyterenin.displaydials</string>
<key>CFBundleExecutable</key><string>DisplayDials</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Finder / file providers may add this attribute to an existing generated bundle.
# Remove only Finder metadata; do not remove quarantine or other security metadata.
xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
