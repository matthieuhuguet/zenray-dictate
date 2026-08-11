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

        fnKey.onPress = { [weak self] in self?.chat.toggle() }
        if !fnKey.start() {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
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
}
