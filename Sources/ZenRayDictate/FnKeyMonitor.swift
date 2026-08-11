import AppKit
import CoreGraphics

/// Watches the globe / Fn key system wide and fires once per press.
///
/// Fn arrives as a flagsChanged event carrying `.maskSecondaryFn`, so a press is
/// the transition from absent to present. Releases are ignored, which is what
/// makes the key behave as a toggle rather than push to talk.
final class FnKeyMonitor {

    var onPress: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var wasDown = false

    /// True when the app already holds the Accessibility right.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility, opening System Settings on the right pane.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        stop()

        // This guard is the whole point of the method.
        //
        // A listen-only session tap is created successfully even when the
        // process is not trusted for Accessibility, but macOS then delivers
        // only the events aimed at this app. The key appears to work while the
        // app is frontmost and to be ignored everywhere else, which reads as a
        // focus bug and is in fact a missing permission. Refusing to start
        // without the right is what makes the app ask for it.
        guard AXIsProcessTrusted() else { return false }

        let mask = (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                me.reenable()
                return Unmanaged.passUnretained(event)
            }

            if type == .flagsChanged {
                let down = event.flags.contains(.maskSecondaryFn)
                if down && !me.wasDown {
                    me.wasDown = true
                    DispatchQueue.main.async { me.onPress?() }
                } else if !down {
                    me.wasDown = false
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,           // never swallow the key
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        wasDown = false
    }
}
