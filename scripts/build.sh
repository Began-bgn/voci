#!/bin/bash
# Builds Voci.app, signs it, and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=.build/release/Voci
APP="$HOME/Applications/Voci.app"

pkill -x Voci 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Voci"
cp -R Vendor/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.voci</string>
    <key>CFBundleName</key><string>Voci</string>
    <key>CFBundleDisplayName</key><string>Voci</string>
    <key>CFBundleExecutable</key><string>Voci</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Voci listens after you press its shortcut, to transcribe your Romanian speech.</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development identity: sign in to Xcode (Settings › Accounts). Using ad-hoc signing." >&2
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "Installed $APP (signed: $IDENTITY)"
