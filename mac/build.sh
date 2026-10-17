#!/bin/bash
# Quick build of DropHop.app for this Mac. Needs Xcode Command Line Tools:
#   xcode-select --install
set -e
cd "$(dirname "$0")"

APP="DropHop.app"
ARCH=$(uname -m)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  DropHop.swift SyncServer.swift -o "$APP/Contents/MacOS/DropHop"

cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DropHop</string>
  <key>CFBundleDisplayName</key><string>DropHop</string>
  <key>CFBundleIdentifier</key><string>com.local.drophop</string>
  <key>CFBundleExecutable</key><string>DropHop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy running it locally
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
open "$APP"
