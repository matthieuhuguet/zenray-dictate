import AppKit
import CoreGraphics

// 4 October 2026: AppKit monitors cover both our own app and all other apps without a disabled Quartz tap.
final class FnKeyMonitor {
    // 7 October 2026, 12:04 CEST: measure the complete physical-key path, including AppKit dispatch delay.
    private static var pendingPressUptime: TimeInterval?
    static func consumePressUptime() -> TimeInterval? {
        defer { pendingPressUptime = nil }
        return pendingPressUptime
    }
    var onPress:(()->Void)?
    var onRelease:(()->Void)?
    var onHandsFree:(()->Void)?
    private var globalMonitor:Any?
    private var localMonitor:Any?
    private var watchdog:Timer?
    private var keyState=FnPressState()
    private var spacePressed=false
    private enum Settings {
        static let healthInterval:TimeInterval=0.25
        static let fnKeyCode:UInt16=63
        static let spaceKeyCode:UInt16=49
        static let eventMask:NSEvent.EventTypeMask=[.flagsChanged,.keyDown]
    }
    static var isTrusted:Bool { AXIsProcessTrusted() }
    static func requestTrust() {
        let key=kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _=AXIsProcessTrustedWithOptions([key:true] as CFDictionary)
    }
    @discardableResult func start()->Bool {
        stop()
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:Settings.eventMask) { [weak self] event in
            self?.receive(event,source:"local");return event
        }
        installGlobalMonitor()
        let timer=Timer(timeInterval:Settings.healthInterval,repeats:true) { [weak self] _ in self?.checkHealth() }
        watchdog=timer;RunLoop.main.add(timer,forMode:.common)
        Log.write("Fn AppKit monitors: local=\(localMonitor != nil), global=\(globalMonitor != nil), accessibility=\(Self.isTrusted), quartzListenAccess=\(CGPreflightListenEventAccess())")
        return localMonitor != nil && globalMonitor != nil && Self.isTrusted
    }
    private func installGlobalMonitor() {
        guard globalMonitor==nil,Self.isTrusted else { return }
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:Settings.eventMask) { [weak self] event in self?.receive(event,source:"global") }
    }
    // 4 October 2026: process the identical event path in local/global handlers and unit tests; never swallow keyboard events.
    func receive(_ event:NSEvent,source:String) {
        if event.type == .keyDown,event.keyCode==Settings.spaceKeyCode,event.modifierFlags.contains(.function),!event.isARepeat {
            Self.pendingPressUptime=event.timestamp
            spacePressed=true;onHandsFree?();return
        }
        guard event.type == .flagsChanged,event.keyCode==Settings.fnKeyCode else { return }
        let down=event.modifierFlags.contains(.function)
        guard let edge=keyState.receive(isDown:down) else { return }
        if edge {
            Self.pendingPressUptime=event.timestamp
            Log.write("Fn AppKit \(source) press; app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
            // Defer changing app/window state until AppKit finishes dispatching this event.
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else { deliverRelease() }
    }
    private func deliverRelease() {
        if !spacePressed { DispatchQueue.main.async { [weak self] in self?.onRelease?() } }
        spacePressed=false
    }
    private func checkHealth() {
        if keyState.recoverRelease(isDown:NSEvent.modifierFlags.contains(.function)) {
            Log.write("Fn AppKit recovered missed release");deliverRelease()
        }
        if globalMonitor==nil,Self.isTrusted { installGlobalMonitor();Log.write("Fn AppKit global monitor restored") }
    }
    func stop() {
        watchdog?.invalidate();watchdog=nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor=nil;localMonitor=nil;keyState=FnPressState();spacePressed=false
    }
}

// 4 October 2026: health checks only repair releases and never invent a press.
struct FnPressState {
    private(set) var isDown=false
    mutating func receive(isDown next:Bool)->Bool? {
        guard next != isDown else { return nil };isDown=next;return next
    }
    mutating func recoverRelease(isDown physical:Bool)->Bool {
        guard isDown && !physical else { return false };isDown=false;return true
    }
}
