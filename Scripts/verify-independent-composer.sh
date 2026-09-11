#!/bin/bash
# Verify the independent composer bundle after a release build.
set -euo pipefail

cd "$(dirname "$0")/.."

./build.sh >/dev/null

test "$(plutil -extract NSMicrophoneUsageDescription raw ZenRayDictate.app/Contents/Info.plist)" != ""
test "$(plutil -extract NSSpeechRecognitionUsageDescription raw ZenRayDictate.app/Contents/Info.plist)" != ""
codesign --verify --deep --strict ZenRayDictate.app
codesign --display --entitlements :- ZenRayDictate.app 2>/dev/null | grep -q 'com.apple.security.device.audio-input'
otool -L ZenRayDictate.app/Contents/MacOS/ZenRayDictate | grep -q 'AVFoundation.framework'
otool -L ZenRayDictate.app/Contents/MacOS/ZenRayDictate | grep -q 'Speech.framework'
if otool -L ZenRayDictate.app/Contents/MacOS/ZenRayDictate | grep -q 'WebKit.framework'; then
    echo "WebKit must not be linked" >&2
    exit 1
fi
grep -q 'kVK_ANSI_D' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'kVK_ANSI_Q' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'controlKey' Sources/ZenRayDictate/AppDelegate.swift
echo "independent composer verification passed"
