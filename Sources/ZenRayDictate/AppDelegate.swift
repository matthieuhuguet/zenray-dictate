import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = DictationEngine()
    private let composer = ComposerWindow()   // the real ChatGPT bar
    private let pill = PillWindow()           // only for failures and notices
    private let fnKey = FnKeyMonitor()          // needs Accessibility
    private let hotKey = GlobalHotKey()         // needs nothing, always works
    private var statusItem: NSStatusItem!
    private var escapeMonitor: Any?
    private var fnWorks = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched, microphone status \(Permissions.microphone.rawValue)")
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
        let trigger: () -> Void = { [weak self] in
            guard let self else { return }
            // The bar comes up on the key press itself, before any round trip
            // to the page, so the shortcut always produces something at once.
            if self.engine.state == .idle, self.engine.isReady {
                self.composer.show(self.engine.webView)
            }
            self.engine.toggle()
        }

        // The permission free shortcut is the one that is guaranteed to work,
        // so it goes in first and stays in whatever happens to Fn.
        hotKey.onPress = trigger
        hotKey.register()

        // Fn is a bonus on top, available only while Accessibility holds.
        fnKey.onPress = trigger
        fnWorks = fnKey.start()
        Log.write("accessibility trusted: \(Permissions.accessibility), Fn active: \(fnWorks)")
        if fnWorks {
            installEscape()
        } else {
            watchForAccessibility()
        }
        rebuildMenu()
    }

    /// Accessibility is granted against the binary's signature, and an ad-hoc
    /// signature changes at every build, so the right can disappear without the
    /// tick in System Settings ever changing. Re-checking keeps Fn honest.
    private func watchForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.fnKey.start() else { return }
            timer.invalidate()
            self.fnWorks = true
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
        if !hotKey.isRegistered {
            status = "Shortcut \(GlobalHotKey.defaultDescription) is taken by another app"
        } else if Permissions.microphone != .authorized {
            status = "Microphone not allowed"
        } else if !engine.isReady {
            status = "Not signed in to ChatGPT"
        } else {
            status = "Press \(GlobalHotKey.defaultDescription) to dictate"
        }
        let hint = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let fnLine = NSMenuItem(
            title: fnWorks ? "Fn also works" : "Fn needs Accessibility",
            action: fnWorks ? nil : #selector(fixAccessibility),
            keyEquivalent: ""
        )
        fnLine.target = fnWorks ? nil : self
        fnLine.isEnabled = !fnWorks
        menu.addItem(fnLine)
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
