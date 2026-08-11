import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = DictationEngine()
    private let composer = ComposerWindow()   // the real ChatGPT bar
    private let pill = PillWindow()           // only for failures and notices
    private let fnKey = FnKeyMonitor()
    private var statusItem: NSStatusItem!
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.warmUp()
        pill.prewarm()
        buildStatusItem()
        wireEngine()
        askForEverything()
    }

    // MARK: - Permissions, asked up front rather than discovered on failure

    private func askForEverything() {
        Permissions.requestMicrophone { [weak self] granted in
            guard let self else { return }
            if !granted {
                self.pill.fail("Microphone blocked",
                               hint: "Allow ZenRayDictate in System Settings > Privacy > Microphone")
                Permissions.openMicrophoneSettings()
            }
            self.startHotKey()
        }
    }

    private func startHotKey() {
        fnKey.onPress = { [weak self] in
            guard let self else { return }
            // The bar comes up on the key press itself, before any round trip
            // to the page, so Fn always produces something on screen at once.
            if self.engine.state == .idle, self.engine.isReady {
                self.composer.show(self.engine.webView)
            }
            self.engine.toggle()
        }

        if fnKey.start() {
            installEscape()
            return
        }

        // Without this right the key only reaches the app while it is
        // frontmost, so there is no point pretending it works.
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        pill.fail("Fn needs Accessibility to work outside this app",
                  hint: "Tick ZenRayDictate in System Settings > Privacy > Accessibility")

        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.fnKey.start() else { return }
            timer.invalidate()
            self.installEscape()
            self.rebuildMenu()
            self.pill.flash("Fn works everywhere now")
        }
    }

    /// Escape always gets you out of a dictation.
    private func installEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }   // Escape
            self?.engine.cancel()
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(for: .idle)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let status: String
        if let gaps = Permissions.missing() {
            status = "Missing \(gaps)"
        } else if !engine.isReady {
            status = "Not signed in to ChatGPT"
        } else {
            status = "Press Fn to dictate"
        }
        let hint = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Sign in to ChatGPT…", #selector(openLogin))
        add(menu, "Hide the ChatGPT window", #selector(closeLogin))
        add(menu, "Reload the session", #selector(reloadSession))
        menu.addItem(.separator())

        if Permissions.microphone != .authorized {
            add(menu, "Fix microphone access…", #selector(fixMicrophone))
        }
        if !Permissions.accessibility {
            add(menu, "Fix accessibility access…", #selector(fixAccessibility))
        }
        add(menu, "Set the globe key to do nothing…", #selector(openKeyboard))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func setIcon(for state: DictationEngine.State) {
        let name: String
        switch state {
        case .idle:                 name = "mic.circle"
        case .starting, .recording: name = "mic.circle.fill"
        case .transcribing:         name = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: name, accessibilityDescription: "ZenRay Dictate"
        )
    }

    // MARK: - Engine

    private func wireEngine() {
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.setIcon(for: state)
            switch state {
            case .starting, .recording, .transcribing:
                self.pill.hide()
                self.composer.show(self.engine.webView)
            case .idle:
                self.composer.hide()
                self.engine.parkWebView()
            }
        }

        engine.onCompactSize = { [weak self] size in
            self?.composer.resize(to: size)
        }

        engine.onTranscript = { [weak self] text in
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                self?.pill.fail("Nothing was heard")
                return
            }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(clean, forType: .string)
            self?.pill.hide()
        }

        engine.onFailure = { [weak self] failure in
            guard let self else { return }
            switch failure {
            case .micBlocked:
                self.pill.fail("Microphone blocked",
                               hint: "Allow ZenRayDictate in System Settings > Privacy > Microphone")
                Permissions.requestMicrophone { granted in
                    if granted { self.engine.load() } else { Permissions.openMicrophoneSettings() }
                }

            case .notSignedIn:
                self.pill.fail("Not signed in to ChatGPT",
                               hint: "Use the menu bar icon to sign in once")
                self.engine.showLoginWindow()

            case .other(let message):
                NSLog("[ZenRayDictate] %@", message)
                self.pill.fail(message)
            }
        }

        engine.onReady = { [weak self] in self?.rebuildMenu() }
    }

    // MARK: - Menu actions

    @objc private func openLogin() { engine.showLoginWindow() }
    @objc private func closeLogin() { engine.hideLoginWindow() }
    @objc private func reloadSession() { engine.load() }
    @objc private func fixMicrophone() { Permissions.openMicrophoneSettings() }
    @objc private func fixAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openKeyboard() { Permissions.openKeyboardSettings() }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}
