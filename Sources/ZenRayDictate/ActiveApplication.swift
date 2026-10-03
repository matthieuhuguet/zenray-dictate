import AppKit
import ApplicationServices
import Carbon.HIToolbox

// 3 October 2026, 16:02 CEST: capture an insertion target once, exclude secure fields and restore clipboard formats.
struct InsertionTarget {
    let application: NSRunningApplication
    let element: AXUIElement?
    let selectedText: String
    let context: String
    let secure: Bool
    let selectedRange: CFTypeRef?
    static func capture(includeContext: Bool) -> InsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication, application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        let element = status == .success && focused != nil && CFGetTypeID(focused!) == AXUIElementGetTypeID() ? (focused as! AXUIElement) : nil
        func read(_ attribute: String) -> CFTypeRef? {
            guard let element else { return nil }
            var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }; return value
        }
        let secure = read(kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        let selection = secure ? "" : read(kAXSelectedTextAttribute) as? String ?? ""
        var context = includeContext && !secure ? String((read(kAXValueAttribute) as? String ?? "").prefix(6000)) : ""
        // 3 October 2026, 19:47 CEST: spelling context includes visible labels in the focused window, with bounded traversal.
        if includeContext && !secure {
            var windowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&windowValue) == .success,
               let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                var visited = 0
                func collect(_ item: AXUIElement, depth: Int) {
                    guard depth < 6, visited < 100, context.count < 6000 else { return }
                    visited += 1
                    var subrole: CFTypeRef?
                    AXUIElementCopyAttributeValue(item,kAXSubroleAttribute as CFString,&subrole)
                    guard subrole as? String != kAXSecureTextFieldSubrole else { return }
                    for attribute in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute] {
                        var value: CFTypeRef?
                        if AXUIElementCopyAttributeValue(item,attribute as CFString,&value) == .success,
                           let text = value as? String, !text.isEmpty { context += "\n" + String(text.prefix(max(0,5999-context.count))) }
                    }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(item,kAXChildrenAttribute as CFString,&children) == .success,
                       let children = children as? [AXUIElement] { for child in children { collect(child,depth:depth+1) } }
                }
                collect(windowValue as! AXUIElement,depth:0)
            }
        }
        context = String(context.prefix(6000))
        return InsertionTarget(application: application, element: element, selectedText: selection, context: context, secure: secure, selectedRange: read(kAXSelectedTextRangeAttribute))
    }
    @MainActor func insert(_ text: String, restoreDelay: Double) async throws {
        guard !secure else { throw TranscriptionError.geminiUnavailable("Dictation does not insert into password fields.") }
        guard AXIsProcessTrusted(), !application.isTerminated else { throw TranscriptionError.geminiUnavailable("Allow Accessibility access to insert text. The result remains in History.") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { throw TranscriptionError.geminiUnavailable("The active application changed. The transcript remains in History; copy it there.") }
        if let element {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            var current: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &current) == .success,
                  let current, CFGetTypeID(current) == AXUIElementGetTypeID(), CFEqual(current,element) else {
                throw TranscriptionError.geminiUnavailable("The insertion field changed; transcript saved in History.")
            }
            if let selectedRange {
                var currentRange: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &currentRange) == .success,
                      let currentRange, CFEqual(currentRange,selectedRange) else { throw TranscriptionError.geminiUnavailable("The cursor or selection moved; transcript saved in History.") }
            }
        }
        var previousValue: String?
        if let element {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXValueAttribute as CFString,&value) == .success { previousValue = value as? String }
        }
        let clipboard = NSPasteboard.general
        let previous = clipboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type,$0) } }
        } ?? []
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else { throw TranscriptionError.geminiUnavailable("Clipboard insertion failed.") }
        let stamp = clipboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { throw TranscriptionError.geminiUnavailable("Paste keyboard event could not be created.") }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: UInt64(max(0.2, restoreDelay) * 1_000_000_000))
        if clipboard.changeCount == stamp {
            clipboard.clearContents()
            let items = previous.map { formats -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in formats { item.setData(data, forType: type) }; return item }
            clipboard.writeObjects(items)
        }
        if let element, let before = previousValue {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXValueAttribute as CFString,&value) == .success,
               let after = value as? String, after == before, !text.isEmpty, text != selectedText {
                throw TranscriptionError.geminiUnavailable("The field did not accept the paste. Copy the saved transcript from History.")
            }
        }
    }
}
