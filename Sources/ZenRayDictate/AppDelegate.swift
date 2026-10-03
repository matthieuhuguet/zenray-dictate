import AppKit
import Carbon.HIToolbox

// Iteration timestamp: 2026-09-11.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let composer = ComposerWindowController(window: nil)
    // 3 October 2026, 21:52 CEST: explicit local modes retain their native path without opening Gemini.
    private var usesWebComposer: Bool { let preferences=DictationLibrary.shared.document.preferences; return !preferences.localOnly && preferences.engine == .gemini }
    private func showDefaultComposer() { if usesWebComposer { TranscriptionPipeline.showComposer() } else { composer.show() } }
    // 3 October 2026, 16:15 CEST: configurable direct dictation complements the preserved native composer.
    private var dictateHotKey: GlobalHotKey?
    private let flow = DictationCoordinator()
    private let libraryWindow = LibraryWindow()
    private let commandHotKey = GlobalHotKey(keyCode:UInt32(kVK_ANSI_D),modifiers:UInt32(controlKey | shiftKey),description:"⌃⇧D")
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
        // 3 October 2026, 21:55 CEST: prevent AirPods reconnection from replacing the built-in input.
        BuiltinMicrophone.shared.onFailure = { error in Log.write(error.localizedDescription) }
        do { try BuiltinMicrophone.shared.start() } catch { Log.write(error.localizedDescription) }
        buildMainMenu()
        buildStatusItem()
        LoginItem.enable()
        showDefaultComposer()

        configureDictationShortcut()
        commandHotKey.onPress = { [weak self] in self?.flow.beginCommand() }
        commandHotKey.onRelease = { [weak self] in self?.flow.endCommand() }
        commandHotKey.register()
        legacyDictateHotKey.onPress = { [weak self] in guard let self else { return }; if self.usesWebComposer { TranscriptionPipeline.toggleLive() } else { self.composer.toggleDictation() } }
        legacyDictateHotKey.register()
        cancelHotKey.onPress = { [weak self] in self?.flow.cancel(); self?.composer.cancelRecording(); if self?.usesWebComposer == true { TranscriptionPipeline.cancelLive() } }
        cancelHotKey.register()

        fnKey.onPress = { [weak self] in
            guard let self else { return }
            if DictationLibrary.shared.document.preferences.fnPushToTalk { if self.usesWebComposer { TranscriptionPipeline.startLive() } else { self.flow.pressFn() } }
            else { self.showDefaultComposer() }
        }
        fnKey.onRelease = { [weak self] in
            guard let self else { return }
            if DictationLibrary.shared.document.preferences.fnPushToTalk { if self.usesWebComposer { TranscriptionPipeline.stopLive() } else { self.flow.releaseFn() } }
        }
        fnKey.onHandsFree = { [weak self] in guard let self else { return }; if self.usesWebComposer { TranscriptionPipeline.liveHandsFree() } else { self.flow.fnSpace() } }
        let fnStarted = fnKey.start()
        Log.write("Fn visibility monitor started: \(fnStarted)")
        if !fnStarted {
            FnKeyMonitor.requestTrust()
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                Task { @MainActor in
                    guard self.fnKey.start() else { return }
                    timer.invalidate()
                    Log.write("Fn visibility monitor started after Accessibility grant")
                }
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
        add(appMenu, "Library, History and Settings", #selector(showLibrary))
        add(appMenu, "Gemini session / Sign in", #selector(showGeminiSession))
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
            title: "Hold Fn to dictate; double Fn or Fn+Space hands-free; hold ⌃⇧D for commands; ⌘D Gemini mic",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Library, History and Settings", #selector(showLibrary))
        add(menu, "Hands-free dictation", #selector(toggleFlow))
        add(menu, "Command Mode", #selector(toggleCommandMode))
        add(menu, "Retry capsule recording", #selector(retryFlow))
        add(menu, "Show Gemini composer", #selector(showComposer))
        add(menu, "Advanced native composer", #selector(showNativeComposer))
        add(menu, "Gemini session / Sign in", #selector(showGeminiSession))
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

    // 3 October 2026, 15:52 CEST: login belongs to the app session, independent of the personal browser.
    @objc private func showGeminiSession() { Task { @MainActor in TranscriptionPipeline.showGemini() } }
    private func configureDictationShortcut() {
        dictateHotKey?.unregister()
        let preferences = DictationLibrary.shared.document.preferences
        let shortcut = GlobalHotKey(keyCode:preferences.shortcutKeyCode,modifiers:preferences.shortcutModifiers,description:"Custom dictation shortcut")
        shortcut.onPress = { [weak self] in self?.toggleFlow() }
        if !shortcut.register() { Log.write("Configured dictation shortcut is unavailable; Fn remains available.") }
        dictateHotKey = shortcut
    }
    @objc private func showLibrary() { libraryWindow.show(coordinator:flow) { [weak self] in self?.configureDictationShortcut() } }
    @objc private func toggleFlow() { if usesWebComposer { TranscriptionPipeline.toggleLive() } else { flow.toggleHandsFree() } }
    @objc private func toggleCommandMode() { flow.toggleCommand() }
    @objc private func retryFlow() { flow.retry() }
    @objc private func showComposer() { showDefaultComposer() }
    @objc private func showNativeComposer() { composer.show() }
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
        showDefaultComposer()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        composer.fadeOut(reason: "app inactive")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictateHotKey?.unregister()
        commandHotKey.unregister()
        legacyDictateHotKey.unregister()
        cancelHotKey.unregister()
        fnKey.stop()
        BuiltinMicrophone.shared.stop()
    }
}
