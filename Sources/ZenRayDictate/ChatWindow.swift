import AppKit
import WebKit

/// A borderless window that CAN become key.
///
/// AppKit denies key window status to any window whose style mask is
/// `.borderless`, by design: borderless was meant for decorative overlays,
/// not for windows the user types into. The consequence was total: every
/// click on a button in the capsule still worked, because clicks do not
/// require key status, but no keystroke ever reached the page, not Escape,
/// not backspace while editing text, nothing, which is what forced quitting
/// the app to escape. Overriding this is the standard fix for a borderless
/// window that still needs to be typed into.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The whole app: one borderless capsule holding real chatgpt.com, trimmed
/// down to its composer bar. Cmd+D drives Start/Stop Dictation directly; Fn
/// shows or hides the window. Clicking Start/Stop by hand on the real page
/// still works too; this class only watches for the transcript and copies it
/// to the clipboard.
final class ChatWindow: NSObject {

    private var window: KeyablePanel!
    private var webView: WKWebView!
    private(set) var isReady = false
    private var isCompact = true
    private var compactSize = CGSize(width: 620, height: 90)
    /// Set once, from the first 'compact' report, and never changed again.
    private var lockedWidth: CGFloat?

    override init() {
        super.init()
        Log.write("web view initialized")
        buildWindow()
        load()
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // session persists across launches

        let controller = WKUserContentController()
        controller.add(self, name: "zenray")
        if let js = Self.bridgeSource() {
            controller.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        config.userContentController = controller

        webView = WKWebView(frame: CGRect(origin: .zero, size: compactSize), configuration: config)
        webView.uiDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        makeTransparent()

        window = KeyablePanel(
            contentRect: CGRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        // AppKit computes a rectangular shadow from the window frame, which
        // sat wrong against a transparent, non-rectangular pill and showed up
        // as a faint curved shape below it. ChatGPT's own CSS already draws
        // the pill's shadow, so the window does not need to draw one too.
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = webView
        window.delegate = self
    }

    /// Without this the web view paints an opaque sheet behind the page, which
    /// would frame the capsule in a visible rectangle.
    private func makeTransparent() {
        webView.setValue(false, forKey: "drawsBackground")
    }

    private static func bridgeSource() -> String? {
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bridge.js")
        return try? String(contentsOf: dev, encoding: .utf8)
    }

    func load() {
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/?temporary-chat=true")!))
    }

    // MARK: - Sign in, the one time the full page is needed

    /// Trimming the page to the composer hides the sidebar, which is also
    /// where the account switcher and login screen live. Signing in needs the
    /// whole page back.
    func showFullPageForSignIn() {
        isCompact = false
        makeOpaqueForFullPage()
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(CGSize(width: 1000, height: 760))
        window.center()
        load()
        show()
    }

    func backToCompact() {
        isCompact = true
        lockedWidth = nil   // a fresh page load earns a fresh measurement
        window.styleMask = [.borderless, .nonactivatingPanel, .resizable]
        makeTransparent()
        load()   // reloading is what re-triggers the compact bridge on 'ready'
    }

    private func makeOpaqueForFullPage() {
        webView.setValue(true, forKey: "drawsBackground")
    }

    // MARK: - Show / hide, the whole interaction

    /// Decided on whether the window is IN FRONT, not merely visible.
    ///
    /// A window can be open yet sitting behind another app; `isVisible` stays
    /// true in that case. Toggling on `isVisible` alone hid a window the user
    /// could not actually see, which produced no change on screen and looked
    /// like the shortcut "only working while the app already had focus".
    func toggle() {
        if window.isKeyWindow {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        position()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// What Cmd+D does: reveal the bar if it was hidden, then click whichever
    /// of Start or Stop Dictation is currently on the page. Stateless by
    /// design, it asks the live DOM rather than tracking a state of its own,
    /// so it can never drift out of sync with what the page is actually doing.
    func toggleDictation() {
        guard AudioInput.selectPreferred() != nil else {
            Log.write("dictation blocked: no MacBook Pro or iPhone microphone")
            return
        }
        if !window.isKeyWindow { show() }
        webView.evaluateJavaScript("window.__zrToggleDictation && window.__zrToggleDictation()") { result, _ in
            Log.write("dictation toggle: \((result as? String) ?? "bridge not ready")")
        }
    }

    private func position() {
        guard isCompact else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.minY + 120
        ))
    }
}

// MARK: - JS bridge

extension ChatWindow: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let payload = (body["payload"] as? String) ?? ""

        switch type {
        case "ready":
            isReady = true

        case "compact":
            guard isCompact,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let w = json["width"] as? Double,
                  let h = json["height"] as? Double else { return }

            // Debouncing the JS side only slowed the loop down, it did not
            // break it, because WIDTH was still being re-applied every time:
            // setContentSize resizes WKWebView (it fills the window's content
            // view exactly), which changes the CSS viewport width the page is
            // laid out at, which can reflow the very composer being watched,
            // which fires the observer again. Locking the width the first
            // time it is known and never touching it again removes that path
            // entirely: only height can still change window to window, and a
            // taller window does not alter the page's rendered width, so it
            // cannot reflow anything horizontally and cannot re-trigger this.
            let width = lockedWidth ?? min(w, 900)
            if lockedWidth == nil { lockedWidth = width }
            let next = CGSize(width: width, height: h)

            guard abs(next.height - compactSize.height) > 1.5 else { return }
            compactSize = next
            window.setContentSize(compactSize)
            position()

        case "transcript":
            let clean = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(clean, forType: .string)
            Log.write("copied \(clean.count) characters to the clipboard")

        case "error":
            Log.write("bridge error: \(payload)")

        default:
            break
        }
    }
}

// MARK: - Microphone permission and window lifecycle

extension ChatWindow: WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    /// Closing the window hides it, it never destroys the session.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}
