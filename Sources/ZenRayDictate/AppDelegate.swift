import AppKit
import Carbon.HIToolbox

// Iteration timestamp: 2026-09-11.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let composer = ComposerWindowController(window: nil)
    private let dictateHotKey = GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey),
        description: "⌃D"
    )
    private let legacyDictateHotKey = GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey),
        description: "⌘D"
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
        buildMainMenu()
        buildStatusItem()
        LoginItem.enable()
        composer.show()

        dictateHotKey.onPress = { [weak self] in self?.composer.toggleDictation() }
        dictateHotKey.register()
        legacyDictateHotKey.onPress = { [weak self] in self?.composer.toggleDictation() }
        legacyDictateHotKey.register()
        cancelHotKey.onPress = { [weak self] in self?.composer.cancelRecording() }
        cancelHotKey.register()

        fnKey.onPress = { [weak self] in
            Log.write("Fn press received")
            self?.composer.toggleVisibility()
        }
        let fnStarted = fnKey.start()
        Log.write("Fn visibility monitor started: \(fnStarted)")
        if !fnStarted {
            FnKeyMonitor.requestTrust()
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.fnKey.start() else { return }
                timer.invalidate()
                Log.write("Fn visibility monitor started after Accessibility grant")
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

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ZenRayDictate")
        appMenu.addItem(withTitle: "About ZenRayDictate", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ZenRayDictate",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let hint = NSMenuItem(
            title: "⌃D or ⌘D starts/stops, ⌃Q cancels, ⌘X cuts all, ⌘Q clears, Fn shows/hides",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Show composer", #selector(showComposer))
        add(menu, "Retry last recording", #selector(retryRecording))
        add(menu, "Copy composer text", #selector(copyComposer))
        add(menu, "Paste into composer", #selector(pasteComposer))
        add(menu, "Retry last copy", #selector(retryCopy))
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
    @objc private func pasteComposer() { composer.pasteComposerText() }
    @objc private func retryCopy() { composer.retryLastCopy() }
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
        legacyDictateHotKey.unregister()
        cancelHotKey.unregister()
        fnKey.stop()
    }
}
