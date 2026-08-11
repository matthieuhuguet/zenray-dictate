import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let chat = ChatWindow()
    private let hotKey = GlobalHotKey()   // Cmd+D, needs no permission
    private let fnKey = FnKeyMonitor()    // Fn, bonus once Accessibility holds
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched")
        buildStatusItem()
        LoginItem.enable()

        Permissions.requestMicrophone { granted in
            if !granted { Permissions.openMicrophoneSettings() }
        }

        // Cmd+D drives the dictation itself: reveal the bar if needed, then
        // click whichever of Start or Stop Dictation the page is showing.
        hotKey.onPress = { [weak self] in self?.chat.toggleDictation() }
        hotKey.register()

        // Fn is a separate, simpler gesture: just show or hide the window.
        fnKey.onPress = { [weak self] in self?.chat.toggle() }
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
            title: "\(GlobalHotKey.defaultDescription) starts/stops dictation, Fn shows/hides",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Show", #selector(showChat))
        add(menu, "Sign in to ChatGPT…", #selector(signIn))
        add(menu, "Back to the compact bar", #selector(backToCompact))
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

    @objc private func showChat() { chat.show() }

    @objc private func signIn() { chat.showFullPageForSignIn() }
    @objc private func backToCompact() { chat.backToCompact() }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled { LoginItem.disable() } else { LoginItem.enable() }
        statusItem.menu = buildMenu()
    }

    /// Clicking the Dock icon while the window is hidden must bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        chat.show()
        return true
    }
}
