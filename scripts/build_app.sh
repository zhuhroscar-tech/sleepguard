#!/bin/bash
# Deterministically package SleepGuardMenuBar as a .app for LOCAL verification.
#
# This produces an ad-hoc signed bundle. Ad-hoc signing proves bundle integrity
# on this machine only. It is NOT Developer ID signing and NOT notarization, and
# nothing here may be described as a distributable or notarized release.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="SleepGuard"
BUNDLE_ID="tech.zhuhroscar.sleepguard"
VERSION="0.2.0-prototype"
DIST="dist"
APP="$DIST/$APP_NAME.app"

swift build -c release --product SleepGuardMenuBar -Xswiftc -warnings-as-errors

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN_PATH="$(swift build -c release --product SleepGuardMenuBar --show-bin-path)"
cp "$BIN_PATH/SleepGuardMenuBar" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu-bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

# Ad-hoc signature: integrity only, explicitly not Developer ID.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP (ad-hoc signed, NOT notarized, NOT for distribution)"
