import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private lazy var codex = CodexController()
    private let hotKey = GlobalHotKey()   // Cmd+D, needs no permission
    private let fnKey = FnKeyMonitor()    // Fn, bonus once Accessibility holds
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched")
        buildStatusItem()
        LoginItem.enable()
        AudioInput.startKeepingPreferred()
        _ = codex

        // Cmd+D drives the native Codex dictation control.
        hotKey.onPress = { [weak self] in self?.codex.toggleDictation() }
        hotKey.register()

        // Fn is a separate, simpler gesture: just show or hide the window.
        fnKey.onPress = { [weak self] in self?.codex.toggle() }
        let fnStarted = fnKey.start()
        Log.write("accessibility trusted: \(Permissions.accessibility), Fn tap started: \(fnStarted)")
        if !fnStarted {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.fnKey.start() { timer.invalidate() }
            }
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.circle", accessibilityDescription: "ZenRay Dictate"
        )
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let hint = NSMenuItem(
            title: "\(GlobalHotKey.defaultDescription) starts/stops Codex dictation, Fn shows/hides Codex",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Show Codex", #selector(showCodex))
        add(menu, "Clear Codex composer", #selector(clearComposer))
        add(menu, "Copy Codex composer", #selector(cutComposer))
        add(menu, "Retry last copy", #selector(retryCopy))
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func showCodex() { codex.show() }
    @objc private func clearComposer() { codex.clearComposer() }
    @objc private func cutComposer() { codex.cutComposer() }
    @objc private func retryCopy() { codex.retryPendingCopy() }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled { LoginItem.disable() } else { LoginItem.enable() }
        statusItem.menu = buildMenu()
    }

    /// Clicking the Dock icon while the window is hidden must bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        codex.show()
        return true
    }
}
