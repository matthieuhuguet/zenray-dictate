#!/bin/bash
# Builds ZenRayDictate.app. Run: ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

APP="ZenRayDictate.app"
BUNDLE_ID="com.zenray.dictate"

echo "==> Compiling"
swift build -c release --arch arm64

BIN=$(swift build -c release --arch arm64 --show-bin-path)/ZenRayDictate

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ZenRayDictate"
cp Sources/ZenRayDictate/Resources/bridge.js "$APP/Contents/Resources/bridge.js"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>ZenRayDictate</string>
    <key>CFBundleDisplayName</key>       <string>ZenRay Dictate</string>
    <key>CFBundleExecutable</key>        <string>ZenRayDictate</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>

    <!-- Menu bar only, no Dock icon, keeps running in the background. -->
    <key>LSUIElement</key>               <true/>

    <!-- The embedded page records your voice. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>ZenRay Dictate records your voice so ChatGPT can transcribe it.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
# A stable ad-hoc signature is what lets macOS remember the Accessibility and
# microphone grants across rebuilds.
codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP" 2>/dev/null || codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

echo
echo "Built $(pwd)/$APP"
echo
echo "First run:"
echo "  open $APP"
echo "  1. Menu bar mic icon > Sign in to ChatGPT, log in, then Hide the window."
echo "  2. Grant Accessibility when asked (needed to watch the Fn key)."
echo "  3. Press Fn to dictate."
