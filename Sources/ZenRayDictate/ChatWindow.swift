import AppKit
import WebKit

/// The whole app: one window holding real chatgpt.com. Fn shows or hides it.
/// You click Start Dictation and Stop Dictation yourself, on the real page.
/// This class only watches for the transcript and copies it to the clipboard.
final class ChatWindow: NSObject {

    private var window: NSWindow!
    private var webView: WKWebView!
    private(set) var isReady = false

    override init() {
        super.init()
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

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: config)
        webView.uiDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "ZenRay Dictate"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
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

    // MARK: - Show / hide, the whole interaction

    /// Decided on whether the window is IN FRONT, not merely visible.
    ///
    /// A window can be open yet sitting behind another app; `isVisible` stays
    /// true in that case. Toggling on `isVisible` alone then hid a window the
    /// user could not actually see, which produced no change on screen and
    /// looked exactly like Fn "only working while the app already had focus".
    func toggle() {
        if window.isKeyWindow {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
