#!/bin/bash
# Verify the independent composer bundle after a release build.
set -euo pipefail

cd "$(dirname "$0")/.."

./build.sh >/dev/null

test "$(plutil -extract NSMicrophoneUsageDescription raw ZenRayDictate.app/Contents/Info.plist)" != ""
codesign --verify --deep --strict ZenRayDictate.app
codesign --display --entitlements :- ZenRayDictate.app 2>/dev/null | grep -q 'com.apple.security.device.audio-input'
otool -L ZenRayDictate.app/Contents/MacOS/ZenRayDictate | grep -q 'AVFoundation.framework'
if otool -L ZenRayDictate.app/Contents/MacOS/ZenRayDictate | grep -q 'WebKit.framework'; then
    echo "WebKit must not be linked" >&2
    exit 1
fi
grep -q 'kVK_ANSI_D' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'description: "⌘D"' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'kVK_ANSI_Q' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'controlKey' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'FnKeyMonitor' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'maskSecondaryFn' Sources/ZenRayDictate/FnKeyMonitor.swift
grep -q 'windowDidResignKey' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'fadeDuration' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'window.contentMaxSize' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'hasHorizontalScroller = false' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'widthTracksTextView = true' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'addLocalMonitorForEvents' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'cutComposerText' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'character == "q"' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'character == "x"' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'pasteAsPlainText' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'buildMainMenu' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'Paste into composer' Sources/ZenRayDictate/AppDelegate.swift
grep -q 'toggleVisibility' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'private final class CircularButton' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'layer.cornerCurve = .circular' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'layer.masksToBounds = true' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'cancelButton.widthAnchor.constraint(equalTo: cancelButton.heightAnchor)' Sources/ZenRayDictate/ComposerWindowController.swift
grep -q 'primaryButton.widthAnchor.constraint(equalTo: primaryButton.heightAnchor)' Sources/ZenRayDictate/ComposerWindowController.swift
if grep -q 'liveTranscript' Sources/ZenRayDictate/ComposerWindowController.swift; then
    echo "live transcript UI must stay removed" >&2
    exit 1
fi
if grep -q '\.resizable' Sources/ZenRayDictate/ComposerWindowController.swift; then
    echo "composer window must stay fixed" >&2
    exit 1
fi
echo "independent composer verification passed"
