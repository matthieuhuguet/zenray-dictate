import AppKit
import WebKit

/// Holds a hidden chatgpt.com page, keeps its session alive, and drives its
/// dictation controls. The transcript comes back through the JS bridge.
final class DictationEngine: NSObject {

    enum State { case idle, recording, transcribing }

    private(set) var state: State = .idle
    private(set) var isReady = false

    var onStateChange: ((State) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?

    private(set) var webView: WKWebView!
    private var loginWindow: NSWindow?
    private var watchdog: Timer?

    override init() {
        super.init()
        buildWebView()
        load()
    }

    // MARK: - Setup

    private func buildWebView() {
        let config = WKWebViewConfiguration()

        // A named data store makes the ChatGPT session survive relaunches.
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.add(self, name: "zenray")
        if let js = Self.bridgeSource() {
            controller.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        config.userContentController = controller

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    private static func bridgeSource() -> String? {
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        // Running the raw SPM binary during development.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bridge.js")
        return try? String(contentsOf: dev, encoding: .utf8)
    }

    func load() {
        isReady = false
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/?temporary-chat=true")!))
    }

    // MARK: - Public control

    /// One Fn press advances the state machine.
    func toggle() {
        switch state {
        case .idle:        start()
        case .recording:   stop()
        case .transcribing: break   // already working, ignore
        }
    }

    func start() {
        guard state == .idle else { return }
        guard isReady else {
            onError?("ChatGPT session not ready. Open the login window from the menu bar.")
            return
        }
        set(.recording)
        webView.evaluateJavaScript("window.__zrStart()") { [weak self] result, _ in
            guard let self else { return }
            if (result as? String) != "recording" {
                self.set(.idle)
                self.onError?("Could not start dictation (\(result as? String ?? "no response")).")
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        set(.transcribing)
        webView.evaluateJavaScript("window.__zrStop()") { [weak self] result, _ in
            guard let self else { return }
            if (result as? String) != "transcribing" {
                self.set(.idle)
                self.onError?("Could not submit dictation (\(result as? String ?? "no response")).")
                return
            }
            // Never hang forever if the response never comes back.
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in
                guard self.state == .transcribing else { return }
                self.set(.idle)
                self.onError?("Transcription timed out.")
            }
        }
    }

    func cancel() {
        webView.evaluateJavaScript("window.__zrCancel()")
        watchdog?.invalidate()
        set(.idle)
    }

    /// Shows the real page so the user can log in once.
    func showLoginWindow() {
        if loginWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "Sign in to ChatGPT"
            w.center()
            w.isReleasedWhenClosed = false
            loginWindow = w
        }
        loginWindow?.contentView = webView
        loginWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Puts the web view back out of sight once login is done.
    func hideLoginWindow() {
        loginWindow?.orderOut(nil)
        loginWindow?.contentView = NSView()
        offscreenHost.addSubview(webView)
    }

    /// The web view must stay in a view hierarchy or WebKit throttles it.
    private lazy var offscreenHost: NSView = {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFront(nil)
        host.addSubview(webView)
        return host
    }()

    func warmUp() { _ = offscreenHost }

    private func set(_ s: State) {
        state = s
        onStateChange?(s)
    }
}

// MARK: - JS bridge

extension DictationEngine: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isReady = true
            onReady?()

        case "transcript":
            watchdog?.invalidate()
            let text = (body["payload"] as? String) ?? ""
            webView.evaluateJavaScript("window.__zrCleanup()")
            set(.idle)
            onTranscript?(text)

        case "error":
            watchdog?.invalidate()
            set(.idle)
            onError?((body["payload"] as? String) ?? "unknown error")

        default:
            break
        }
    }
}

// MARK: - Permissions and navigation

extension DictationEngine: WKUIDelegate, WKNavigationDelegate {

    /// Grants the microphone to the page without a second prompt. macOS still
    /// asks the user once, for the app itself.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // bridge.js reports readiness on its own once the composer exists.
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?("Page failed to load: \(error.localizedDescription)")
    }
}
