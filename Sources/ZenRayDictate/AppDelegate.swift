import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let chat = ChatWindow()
    private let fnKey = FnKeyMonitor()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched")
        buildStatusItem()

        Permissions.requestMicrophone { granted in
            if !granted { Permissions.openMicrophoneSettings() }
        }

        fnKey.onPress = { [weak self] in
            Log.write("Fn pressed")
            self?.chat.toggle()
        }
        let fnStarted = fnKey.start()
        Log.write("accessibility trusted: \(Permissions.accessibility), Fn tap started: \(fnStarted)")
        if !fnStarted {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.fnKey.start() {
                    timer.invalidate()
                    Log.write("Fn tap started after granting accessibility")
                }
            }
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.circle", accessibilityDescription: "ZenRay Dictate"
        )

        let menu = NSMenu()

        let hint = NSMenuItem(title: "Press Fn to show ChatGPT", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Show ChatGPT", #selector(showChat))
        add(menu, "Reload the session", #selector(reload))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func showChat() { chat.show() }
    @objc private func reload() { chat.load() }

    /// Clicking the Dock icon while the window is hidden must bring it back.
    /// Without this, orderOut(nil) leaves the app running with no visible way
    /// in from the Dock, which defeats the point of having an icon there.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        chat.show()
        return true
    }
}
