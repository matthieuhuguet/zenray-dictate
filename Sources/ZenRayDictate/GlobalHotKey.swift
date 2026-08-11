import AppKit
import Carbon.HIToolbox

/// A system wide shortcut that needs no permission at all.
///
/// RegisterEventHotKey goes through the window server rather than an event
/// tap, so unlike Fn it asks for nothing and works the moment the app
/// launches. The cost is that whichever combination is chosen stops reaching
/// every other app while ZenRayDictate is running, so it is worth picking one
/// that is not already load bearing elsewhere.
final class GlobalHotKey {

    var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private(set) var isRegistered = false

    /// Cmd+D. Chosen on request; it does shadow Cmd+D in every other app
    /// while ZenRayDictate runs (Safari's Add Bookmark, Finder's Duplicate),
    /// which is the trade the shorter combination buys.
    static let defaultKeyCode = UInt32(kVK_ANSI_D)
    static let defaultModifiers = UInt32(cmdKey)
    static let defaultDescription = "⌘D"

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
        isRegistered = (status == noErr && ref != nil)
        Log.write(isRegistered
            ? "shortcut registered: keyCode \(keyCode), modifiers \(modifiers)"
            : "shortcut FAILED to register, OSStatus \(status) (likely taken by another app)")
        return isRegistered
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        isRegistered = false
        Self.instances[id] = nil
    }

    deinit { unregister() }
}
