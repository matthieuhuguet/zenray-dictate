import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Controls the installed Codex composer through macOS Accessibility.
/// Codex owns the native composer, microphone, live transcript, and retry UI.
final class CodexController: NSObject {

    private enum DictationState {
        case idle
        case starting
        case recording
        case stopping
    }

    private static let bundleIdentifier = "com.openai.codex"
    private static let composerPlaceholder = "do anything"
    private static let stopPollInterval: TimeInterval = 0.12
    private static let stopStableSamplesRequired = 10
    private static let stopMaxAttempts = 125

    private var state: DictationState = .idle
    private var beforeDictationText = ""
    private var lastComposerText = ""
    private var pendingCopyText: String?
    private var trackingTimer: Timer?
    private var stopTimer: Timer?
    private var toggleSerial = 0

    override init() {
        super.init()
        Log.write("Codex controller initialized")
    }

    deinit {
        trackingTimer?.invalidate()
        stopTimer?.invalidate()
    }

    func show() {
        activateCodex { [weak self] app in
            guard let self, let app else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.focusComposer(in: app)
            }
        }
    }

    func toggle() {
        guard let app = runningCodex() else {
            show()
            return
        }

        if app.isActive {
            app.hide()
            Log.write("Codex hidden")
        } else {
            show()
        }
    }

    func clearComposer() {
        activateCodex { [weak self] app in
            guard let self, let app, let composer = self.composerElement(in: app) else {
                Log.write("clear composer failed: Codex composer unavailable")
                return
            }

            guard self.setComposerText("", in: composer, app: app) else {
                Log.write("clear composer failed: Accessibility value is not settable")
                return
            }
            self.lastComposerText = ""
            Log.write("Codex composer cleared")
        }
    }

    func cutComposer() {
        activateCodex { [weak self] app in
            guard let self, let app, let composer = self.composerElement(in: app) else {
                Log.write("cut composer failed: Codex composer unavailable")
                return
            }

            let text = self.composerText(from: composer)
            guard !text.isEmpty else { return }
            guard self.copyToClipboard(text, action: "cut") else { return }
            guard self.setComposerText("", in: composer, app: app) else {
                Log.write("cut composer failed: composer could not be cleared")
                return
            }
            self.lastComposerText = ""
        }
    }

    func retryPendingCopy() {
        guard let text = pendingCopyText, !text.isEmpty else {
            Log.write("no pending Codex transcript to retry")
            return
        }
        if copyToClipboard(text, action: "retried") {
            pendingCopyText = nil
        }
    }

    func toggleDictation() {
        guard AXIsProcessTrusted() else {
            Permissions.requestAccessibility()
            Log.write("dictation blocked: Accessibility permission is missing")
            return
        }

        if let pendingCopyText, !pendingCopyText.isEmpty, state == .idle {
            retryPendingCopy()
            return
        }

        switch state {
        case .starting, .recording:
            stopDictation()
        case .stopping:
            Log.write("dictation toggle ignored: Codex is finishing the transcript")
        case .idle:
            startDictation()
        }
    }

    private func startDictation() {
        toggleSerial += 1
        let serial = toggleSerial
        state = .starting
        activateCodex { [weak self] app in
            guard let self, serial == self.toggleSerial, self.state == .starting else {
                return
            }
            guard let app else {
                self.state = .idle
                Log.write("dictation start failed: Codex did not launch")
                return
            }
            self.attemptStart(in: app, serial: serial, retriesRemaining: 32)
        }
    }

    private func stopDictation() {
        guard let app = runningCodex() else {
            state = .idle
            Log.write("dictation stop failed: Codex is not running")
            return
        }
        app.activate(options: [.activateAllWindows])
        state = .stopping
        stopTimer?.invalidate()

        if let button = dictationButton(in: app, stopping: true) {
            if press(button, named: "Stop dictation") {
                Log.write("Codex native Stop dictation pressed")
            } else {
                postDictationShortcut(to: app)
            }
        } else {
            // Codex's stop label can be transient while the native composer updates.
            postDictationShortcut(to: app)
        }
        beginStopTracking(in: app)
    }

    private func attemptStart(in app: NSRunningApplication,
                              serial: Int,
                              retriesRemaining: Int) {
        guard serial == toggleSerial, state == .starting else { return }

        if let button = dictationButton(in: app, stopping: false) {
            let before = actualComposerText(composerText(in: app) ?? "")
            beforeDictationText = before
            lastComposerText = before
                if press(button, named: "Dictate") {
                    state = .recording
                    stopTimer?.invalidate()
                    startComposerTracking(in: app)
                    Log.write("Codex dictation started")
                    return
                }
            }

            guard retriesRemaining > 0 else {
            state = .idle
            Log.write("dictation start failed: Codex Dictate control unavailable")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.attemptStart(in: app, serial: serial, retriesRemaining: retriesRemaining - 1)
        }
    }

    private func beginStopTracking(in app: NSRunningApplication) {
        trackingTimer?.invalidate()
        var attempts = 0
        var previous = ""
        var stableSamples = 0

        stopTimer = Timer.scheduledTimer(withTimeInterval: Self.stopPollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            attempts += 1
            let current = self.actualComposerText(self.composerText(in: app) ?? self.lastComposerText)
            if current == previous {
                stableSamples += 1
            } else {
                previous = current
                stableSamples = 0
            }

            let hasDictatedText = !current.isEmpty &&
                current != self.beforeDictationText
            if hasDictatedText && stableSamples >= Self.stopStableSamplesRequired {
                timer.invalidate()
                self.finishStop(with: current)
                return
            }

            if attempts >= Self.stopMaxAttempts {
                timer.invalidate()
                if !current.isEmpty && current != self.beforeDictationText {
                    self.finishStop(with: current)
                } else {
                    self.state = .idle
                    Log.write("Codex dictation stopped without transcript; Codex keeps its native retry state")
                }
            }
        }
    }

    private func finishStop(with text: String) {
        trackingTimer?.invalidate()
        state = .idle
        let clean = actualComposerText(text)
        guard !clean.isEmpty, clean != beforeDictationText else {
            Log.write("Codex dictation stopped without text")
            return
        }

        if copyToClipboard(clean, action: "copied") {
            pendingCopyText = nil
        } else {
            pendingCopyText = clean
            Log.write("Codex transcript kept in memory for retry")
        }
    }

    private func startComposerTracking(in app: NSRunningApplication) {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let text = self.composerText(in: app) else { return }
            self.lastComposerText = self.actualComposerText(text)
        }
    }

    private func activateCodex(completion: @escaping (NSRunningApplication?) -> Void) {
        if let app = runningCodex() {
            app.activate(options: [.activateAllWindows])
            completion(app)
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            Log.write("Codex unavailable: application not installed")
            completion(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                Log.write("Codex launch failed: \(error.localizedDescription)")
            } else if app != nil {
                Log.write("Codex launched")
            }
            DispatchQueue.main.async {
                completion(app)
            }
        }
    }

    private func runningCodex() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func focusComposer(in app: NSRunningApplication) {
        guard let composer = composerElement(in: app) else { return }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(app.processIdentifier),
            kAXFocusedUIElementAttribute as CFString,
            composer
        )
    }

    private func press(_ element: AXUIElement, named name: String) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            Log.write("Codex \(name) press failed: AXError \(result.rawValue)")
            return false
        }
        return true
    }

    private func postDictationShortcut(to app: NSRunningApplication) {
        app.activate(options: [.activateAllWindows])
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: true)
        down?.flags = [.maskControl, .maskShift]
        down?.postToPid(app.processIdentifier)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: false)
        up?.flags = [.maskControl, .maskShift]
        up?.postToPid(app.processIdentifier)
        Log.write("Codex dictation shortcut sent: Control-Shift-D")
    }

    private func copyToClipboard(_ text: String, action: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            Log.write("\(action) Codex transcript failed: pasteboard rejected the string")
            return false
        }
        Log.write("\(action) \(text.count) characters to the clipboard")
        return true
    }

    private func setComposerText(_ text: String,
                                 in composer: AXUIElement,
                                 app: NSRunningApplication) -> Bool {
        var settable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(
            composer,
            kAXValueAttribute as CFString,
            &settable
        )
        if settable.boolValue {
            let value = text as NSString
            if AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, value) == .success {
                return true
            }
        }

        focusComposer(in: app)
        postKey(virtualKey: CGKeyCode(kVK_ANSI_A), flags: .maskCommand, to: app)
        postKey(virtualKey: CGKeyCode(kVK_Delete), flags: [], to: app)
        return text.isEmpty
    }

    private func postKey(virtualKey: CGKeyCode,
                        flags: CGEventFlags,
                        to app: NSRunningApplication) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.postToPid(app.processIdentifier)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.postToPid(app.processIdentifier)
    }

    private func composerText(in app: NSRunningApplication) -> String? {
        guard let composer = composerElement(in: app) else { return nil }
        return composerText(from: composer)
    }

    private func composerText(from element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value else { return "" }
        if let text = value as? String { return text }
        if let text = value as? NSString { return text as String }
        return String(describing: value)
    }

    private func actualComposerText(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.caseInsensitiveCompare(Self.composerPlaceholder) != .orderedSame else {
            return ""
        }
        return clean
    }

    private func composerElement(in app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var candidates: [AXUIElement] = []
        walk(root) { element in
            guard axString(element, kAXRoleAttribute as CFString) == "AXTextArea",
                  isVisible(element) else { return }
            candidates.append(element)
        }

        return candidates.first(where: {
            axMetadata($0).localizedCaseInsensitiveContains(Self.composerPlaceholder)
        }) ?? candidates.first
    }

    private func dictationButton(in app: NSRunningApplication,
                                 stopping: Bool) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var candidates: [AXUIElement] = []
        walk(root) { element in
            guard axString(element, kAXRoleAttribute as CFString) == "AXButton",
                  isVisible(element) else { return }
            let metadata = axMetadata(element).lowercased()
            if stopping {
                if metadata.contains("stop dictation") || metadata.contains("stop recording") ||
                    metadata.contains("finish dictation") || metadata.contains("end dictation") {
                    candidates.append(element)
                }
            } else if metadata == "dictate" || metadata.contains("start dictation") ||
                        metadata.contains("begin dictation") {
                candidates.append(element)
            }
        }
        return candidates.first
    }

    private func walk(_ element: AXUIElement,
                      depth: Int = 0,
                      visit: (AXUIElement) -> Void) {
        guard depth < 64 else { return }
        visit(element)
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, visit: visit)
        }
    }

    private func axMetadata(_ element: AXUIElement) -> String {
        [
            axString(element, kAXTitleAttribute as CFString),
            axString(element, kAXDescriptionAttribute as CFString),
            axString(element, kAXHelpAttribute as CFString),
            axString(element, kAXIdentifierAttribute as CFString),
            axString(element, kAXValueAttribute as CFString)
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func axString(_ element: AXUIElement, _ attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return "" }
        if let text = value as? String { return text }
        if let text = value as? NSString { return text as String }
        return String(describing: value)
    }

    private func isVisible(_ element: AXUIElement) -> Bool {
        let hidden = axString(element, kAXHiddenAttribute as CFString).lowercased()
        return hidden != "1" && hidden != "true"
    }
}
