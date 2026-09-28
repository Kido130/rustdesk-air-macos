#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$repo/target/air-fixtures}"
app="$output/RustDesk Air Sticky Fixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>StickyFixture</string>
  <key>CFBundleIdentifier</key><string>com.rustdesk.air.sticky-fixture</string>
  <key>CFBundleName</key><string>RustDesk Air Sticky Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
clang++ -std=c++17 -fobjc-arc -fobjc-weak -ObjC++ \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  "$repo/src/air/tests/spaces_sticky_own_window_fixture.mm" \
  -o "$app/Contents/MacOS/StickyFixture"
codesign --force --sign - "$app" >/dev/null
printf '%s\n' "$app/Contents/MacOS/StickyFixture"
