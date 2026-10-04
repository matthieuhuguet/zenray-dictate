import AppKit
import CoreGraphics

// Iteration timestamp: 2026-09-11.
/// Watches the Fn key system wide and fires once per press.
final class FnKeyMonitor {

    // 3 October 2026, 16:10 CEST: release and Fn+Space complete push-to-talk and hands-free triggers.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onHandsFree: (() -> Void)?
    private var spacePressed = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyState = FnPressState()
    private var watchdog: Timer?
    private enum Settings {
        static let healthInterval: TimeInterval = 0.25
        static let fnKeyCode: Int64 = 63
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        // 4 October 2026: recovery survives focus changes, missed releases and disabled taps.
        let timer=Timer(timeInterval:Settings.healthInterval,repeats:true) { [weak self] _ in self?.checkHealth() }
        watchdog=timer
        RunLoop.main.add(timer,forMode:.common)
        return installTap()
    }

    private func installTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.reenable()
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown, event.flags.contains(.maskSecondaryFn), event.getIntegerValueField(.keyboardEventKeycode) == 49 {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { monitor.spacePressed = true; DispatchQueue.main.async { monitor.onHandsFree?() } }
            }
            if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode)==Settings.fnKeyCode {
                let isDown=event.flags.contains(.maskSecondaryFn)
                if let edge=monitor.keyState.receive(isDown:isDown) {
                    if edge { DispatchQueue.main.async { Log.write("Fn global press; app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")"); monitor.onPress?() } }
                    else { monitor.deliverRelease() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func deliverRelease() {
        if !spacePressed { DispatchQueue.main.async { self.onRelease?() } }
        spacePressed=false
    }
    private func checkHealth() {
        if keyState.recoverRelease(isDown:CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)) {
            Log.write("Fn recovered missed release")
            deliverRelease()
        }
        if let tap,CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap:tap) { reenable() }
        } else {
            removeTap()
            if installTap() { Log.write("Fn global listener restored") }
        }
    }
    private func reenable() {
        if let tap { CGEvent.tapEnable(tap:tap,enable:true);DispatchQueue.main.async { Log.write("Fn global listener re-enabled") } }
    }

    func stop() {
        watchdog?.invalidate();watchdog=nil
        removeTap()
        keyState=FnPressState();spacePressed=false
    }
    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}

// 4 October 2026: only event edges trigger capture; health checks repair releases without inventing presses.
struct FnPressState {
    private(set) var isDown=false
    mutating func receive(isDown next:Bool) -> Bool? {
        guard next != isDown else { return nil }
        isDown=next;return next
    }
    mutating func recoverRelease(isDown physical:Bool) -> Bool {
        guard isDown && !physical else { return false }
        isDown=false;return true
    }
}
