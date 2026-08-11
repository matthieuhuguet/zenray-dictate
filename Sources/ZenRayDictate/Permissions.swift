import AppKit
import AVFoundation

/// Everything macOS has to grant before a single word can be dictated.
/// The app asks for all of it at launch instead of letting the user discover
/// the gaps one failure at a time.
enum Permissions {

    // MARK: - Microphone

    static var microphone: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the system prompt the first time, and reports the outcome after.
    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch microphone {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)   // denied or restricted, only Settings can undo it
        }
    }

    // MARK: - Accessibility

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Settings panes

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// The pane where the globe key is reassigned, which is the one setting
    /// that silently breaks Fn if it is left on its default.
    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - Summary

    /// nil when everything is in place, otherwise what is still missing.
    static func missing() -> String? {
        var gaps: [String] = []
        if microphone != .authorized { gaps.append("microphone") }
        if !accessibility { gaps.append("accessibility") }
        return gaps.isEmpty ? nil : gaps.joined(separator: " and ")
    }
}
