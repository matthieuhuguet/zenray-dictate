import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = DictationEngine()
    private let pill = PillWindow()
    private let fnKey = FnKeyMonitor()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.warmUp()
        buildStatusItem()
        wireEngine()
        startHotKey()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.circle", accessibilityDescription: "ZenRay Dictate"
        )

        let menu = NSMenu()

        let hint = NSMenuItem(title: "Press Fn to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Sign in to ChatGPT…", action: #selector(openLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let hide = NSMenuItem(title: "Hide the ChatGPT window", action: #selector(closeLogin), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let reload = NSMenuItem(title: "Reload the session", action: #selector(reloadSession), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let trust = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
        trust.target = self
        menu.addItem(trust)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setIcon(for state: DictationEngine.State) {
        let name: String
        switch state {
        case .idle:         name = "mic.circle"
        case .recording:    name = "mic.circle.fill"
        case .transcribing: name = "ellipsis.circle"
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
            case .recording:    self.pill.show(state: .recording)
            case .transcribing: self.pill.update(state: .transcribing)
            case .idle:         self.pill.hide()
            }
        }

        engine.onTranscript = { [weak self] text in
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                self?.pill.flash(message: "Nothing was heard")
                return
            }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(clean, forType: .string)
            self?.pill.hide()
        }

        engine.onError = { [weak self] message in
            NSLog("[ZenRayDictate] %@", message)
            self?.pill.flash(message: message)
        }
    }

    // MARK: - Hot key

    private func startHotKey() {
        fnKey.onPress = { [weak self] in self?.engine.toggle() }

        if fnKey.start() { return }

        FnKeyMonitor.requestTrust()
        pill.flash(message: "Allow Accessibility, then it starts on its own")

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.fnKey.start() {
                timer.invalidate()
                self.pill.flash(message: "Fn is ready")
            }
        }
    }

    // MARK: - Menu actions

    @objc private func openLogin() { engine.showLoginWindow() }
    @objc private func closeLogin() { engine.hideLoginWindow() }
    @objc private func reloadSession() { engine.load() }
    @objc private func grantAccessibility() { FnKeyMonitor.requestTrust() }
}
