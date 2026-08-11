import AppKit
import Carbon.HIToolbox

/// A system wide shortcut that needs no permission at all.
///
/// This exists because the Fn route is fragile in a way that is nobody's fault:
/// a listen-only event tap requires Accessibility, and Accessibility is granted
/// against the binary's signature, which changes at every build of an ad-hoc
/// signed app. The tick stays in System Settings while macOS quietly stops
/// trusting the new build, so the key appears granted and does nothing.
///
/// RegisterEventHotKey goes through the window server instead. It works from any
/// app, survives rebuilds, and asks for nothing. The cost is that it cannot bind
/// a bare modifier such as Fn, so it takes a real combination.
final class GlobalHotKey {

    var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    /// Control Option D, chosen because macOS ships nothing on it.
    static let defaultKeyCode = UInt32(kVK_ANSI_D)
    static let defaultModifiers = UInt32(controlKey | optionKey)

    /// How the shortcut reads in a menu.
    static let defaultDescription = "⌃⌥D"

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    @discardableResult
    func register(keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
                  modifiers: UInt32 = GlobalHotKey.defaultModifiers) -> Bool {
        unregister()

        Self.instances[id] = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if let instance = GlobalHotKey.instances[hotKeyID.id] {
                DispatchQueue.main.async { instance.onPress?() }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5A52_4459), id: id)  // 'ZRDY'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        return status == noErr && ref != nil
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        Self.instances[id] = nil
    }

    deinit { unregister() }
}
