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
if [[ -f AppIcon.icns ]]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>ZenRayDictate</string>
    <key>CFBundleDisplayName</key>       <string>ZenRay Dictate</string>
    <key>CFBundleExecutable</key>        <string>ZenRayDictate</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>

    <!-- Regular app: shows in the Dock, so clicking the icon is a way in that
         does not depend on Fn or on a crowded menu bar. -->

</dict>
</plist>
PLIST

echo "==> Signing"
# An ad-hoc signature (--sign -) is derived from the binary's own hash, so it
# changes at every build. TCC grants (Accessibility, Microphone) are tied to
# the signature, so they were silently revoked on every rebuild even with the
# tick left on in System Settings. A local certificate keeps the signature
# stable across builds, so permissions granted once actually stay granted.
# Run ./make-certificate.sh once if this identity does not exist yet.
SIGN_ID="ZenRayDictate Local"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "    No '$SIGN_ID' certificate found, run ./make-certificate.sh once."
    echo "    Falling back to an ad-hoc signature for now (permissions will not persist)."
    SIGN_ID="-"
fi

codesign --force --deep --sign "$SIGN_ID" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements Entitlements.plist \
    "$APP"

echo
echo "Built $(pwd)/$APP"
echo
echo "First run:"
echo "  open $APP"
echo "  1. Open Codex and grant it microphone access."
echo "  2. Grant ZenRay Dictate Accessibility access for the global controls."
echo "  3. Press Fn to show or hide Codex."
echo "  4. Press Cmd+D to start or stop Codex dictation."
