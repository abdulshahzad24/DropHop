#!/bin/bash
# Builds a universal (Apple Silicon + Intel) DropHop.app and packages it into DropHop.dmg
# Needs Xcode Command Line Tools:  xcode-select --install
#
# Optional (warning-free install on other people's Macs, needs the $99/yr Apple Developer account):
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" bash make-dmg.sh
set -e
cd "$(dirname "$0")"

APP="DropHop.app"
DMG="DropHop.dmg"
STAGE="dmg-stage"

rm -rf "$APP" "$DMG" "$STAGE" build-arm64 build-x86_64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling for Apple Silicon..."
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13.0 \
  DropHop.swift SyncServer.swift -o build-arm64

echo "Compiling for Intel..."
swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13.0 \
  DropHop.swift SyncServer.swift -o build-x86_64

lipo -create build-arm64 build-x86_64 -output "$APP/Contents/MacOS/DropHop"
rm -f build-arm64 build-x86_64

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

if [ -n "$DEV_ID" ]; then
  echo "Signing with Developer ID..."
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
else
  echo "Ad-hoc signing (others will need to right-click > Open the first time)..."
  codesign --force --sign - "$APP"
fi

echo "Creating DMG..."
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DropHop" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$DEV_ID" ]; then
  codesign --force --sign "$DEV_ID" "$DMG"
  echo
  echo "To notarize (removes the security warning), run:"
  echo "  xcrun notarytool submit $DMG --apple-id YOU@EMAIL --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait"
  echo "  xcrun stapler staple $DMG"
fi

echo
echo "Done: $(pwd)/$DMG"
[ -n "$CI" ] || open -R "$DMG"
