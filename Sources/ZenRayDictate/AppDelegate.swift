import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let composer = ComposerWindowController(window: nil)
    private let dictateHotKey = GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey),
        description: "⌃D"
    )
    private let cancelHotKey = GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_Q),
        modifiers: UInt32(controlKey),
        description: "⌃Q"
    )
    private let fnKey = FnKeyMonitor()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched")
        buildStatusItem()
        LoginItem.enable()
        composer.show()

        dictateHotKey.onPress = { [weak self] in self?.composer.toggleDictation() }
        dictateHotKey.register()
        cancelHotKey.onPress = { [weak self] in self?.composer.cancelRecording() }
        cancelHotKey.register()

        fnKey.onPress = { [weak self] in
            Log.write("Fn press received")
            self?.composer.fadeOut(reason: "Fn")
        }
        let fnStarted = fnKey.start()
        Log.write("Fn fade-out monitor started: \(fnStarted)")
        if !fnStarted {
            FnKeyMonitor.requestTrust()
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.fnKey.start() else { return }
                timer.invalidate()
                Log.write("Fn fade-out monitor started after Accessibility grant")
            }
        }

        Log.write("independent composer ready; Codex chat remains a separate app")
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
            title: "⌃D starts/stops, ⌃Q cancels, ⌘X cuts all, ⌘Q clears, Fn fades out",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Show composer", #selector(showComposer))
        add(menu, "Retry last recording", #selector(retryRecording))
        add(menu, "Copy composer text", #selector(copyComposer))
        add(menu, "Clear composer", #selector(clearComposer))
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

    @objc private func showComposer() { composer.show() }
    @objc private func clearComposer() { composer.clearComposer() }
    @objc private func copyComposer() { composer.copyComposerText() }
    @objc private func retryRecording() { composer.retryPendingRecording() }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled { LoginItem.disable() } else { LoginItem.enable() }
        statusItem.menu = buildMenu()
    }

    /// Clicking the Dock icon while the window is hidden must bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        composer.show()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        composer.fadeOut(reason: "app inactive")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictateHotKey.unregister()
        cancelHotKey.unregister()
        fnKey.stop()
    }
}
