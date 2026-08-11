import AppKit
import WebKit

/// Holds a hidden chatgpt.com page, keeps its session alive, and drives its
/// dictation controls. The transcript comes back through the JS bridge.
///
/// No state is entered on hope. `.starting` only becomes `.recording` once the
/// page confirms it really is dictating, and every state carries a watchdog, so
/// the pill can never be left hanging on `Listening…`.
final class DictationEngine: NSObject {

    enum State { case idle, starting, recording, transcribing }

    enum Failure {
        case micBlocked
        case notSignedIn
        case other(String)
    }

    private(set) var state: State = .idle
    private(set) var isReady = false

    var onStateChange: ((State) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onFailure: ((Failure) -> Void)?
    var onReady: (() -> Void)?
    var onCompactSize: ((CGSize) -> Void)?

    /// Whether the page should be stripped down to its composer. False only
    /// while the full ChatGPT window is open for signing in.
    private var wantsCompact = true

    private(set) var webView: WKWebView!
    private var loginWindow: NSWindow?
    private var watchdog: Timer?

    /// Longest a single dictation may run before it is submitted on its own.
    private let maxRecordingSeconds: TimeInterval = 180

    override init() {
        super.init()
        buildWebView()
        load()
    }

    // MARK: - Setup

    private func buildWebView() {
        let config = WKWebViewConfiguration()
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
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bridge.js")
        return try? String(contentsOf: dev, encoding: .utf8)
    }

    func load() {
        isReady = false
        stopWatchdog()
        set(.idle)
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/?temporary-chat=true")!))
    }

    // MARK: - Public control

    /// One Fn press advances the state machine.
    func toggle() {
        switch state {
        case .idle:                   start()
        case .starting, .recording:   stop()
        case .transcribing:           break   // already working, ignore
        }
    }

    func start() {
        guard state == .idle else { return }
        guard isReady else {
            onFailure?(.notSignedIn)
            return
        }

        set(.starting)
        // The bridge waits up to twice four seconds and retries once, so this
        // only fires if the page stopped answering altogether.
        arm(seconds: 11) { [weak self] in
            guard let self, self.state == .starting else { return }
            self.set(.idle)
            self.onFailure?(.other("ChatGPT stopped responding."))
            self.logDiagnosis()
        }
        webView.evaluateJavaScript("window.__zrStart()")
    }

    func stop() {
        guard state == .starting || state == .recording else { return }
        set(.transcribing)
        arm(seconds: 30) { [weak self] in
            guard let self, self.state == .transcribing else { return }
            self.set(.idle)
            self.onFailure?(.other("Transcription timed out."))
        }
        webView.evaluateJavaScript("window.__zrStop()") { [weak self] result, _ in
            guard let self else { return }
            if (result as? String) == "not-recording" {
                self.stopWatchdog()
                self.set(.idle)
            }
        }
    }

    /// Escape hatch. Throws the dictation away and returns to rest.
    func cancel() {
        guard state != .idle else { return }
        webView.evaluateJavaScript("window.__zrCancel()")
        stopWatchdog()
        set(.idle)
    }

    // MARK: - Login window

    func showLoginWindow() {
        // Signing in needs the whole page back, not the composer alone.
        if wantsCompact {
            wantsCompact = false
            webView.setValue(true, forKey: "drawsBackground")
            load()
        }
        if loginWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "ChatGPT"
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            loginWindow = w
        }
        webView.removeFromSuperview()
        loginWindow?.contentView = webView
        loginWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideLoginWindow() {
        loginWindow?.orderOut(nil)
        loginWindow?.contentView = NSView()
        if !wantsCompact {
            wantsCompact = true
            load()          // comes back compacted once ready
        }
        parkWebView()
    }

    /// Puts the web view back in its one point window, where the page stays
    /// awake between dictations.
    func parkWebView() {
        webView.removeFromSuperview()
        // A desktop sized frame keeps ChatGPT in its wide layout, which is the
        // one carrying the dictation controls the bridge looks for.
        webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        webView.autoresizingMask = []
        stealthHost.addSubview(webView)
        stealthWindow?.orderFront(nil)
    }

    /// Where the web view lives when the ChatGPT window is closed.
    ///
    /// It cannot simply be parked offscreen or at alpha zero: macOS then reports
    /// the window as occluded, WebKit suspends the page, and the dictation never
    /// starts. That is exactly the "ChatGPT did not enter dictation mode" the app
    /// used to show as soon as the window was hidden.
    ///
    /// So the window stays genuinely visible, but one point wide, parked in a
    /// screen corner and sitting below every ordinary window. The web view keeps
    /// its full size inside it and is clipped away by the window bounds, which
    /// leaves the page laid out for desktop and fully awake.
    private lazy var stealthHost: NSView = {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        window.orderFront(nil)

        stealthWindow = window
        host.addSubview(webView)
        return host
    }()

    private var stealthWindow: NSWindow?

    func warmUp() { _ = stealthHost }

    // MARK: - Internals

    private func set(_ s: State) {
        guard state != s else { return }
        state = s
        onStateChange?(s)
    }

    private func arm(seconds: TimeInterval, _ block: @escaping () -> Void) {
        stopWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in block() }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Writes what the page actually looked like when it refused, so a failure
    /// can be diagnosed from the log instead of guessed at.
    func logDiagnosis() {
        webView.evaluateJavaScript("window.__zrDiagnose && window.__zrDiagnose()") { result, _ in
            NSLog("[ZenRayDictate] page state: %@", (result as? String) ?? "no bridge")
        }
    }
}

// MARK: - JS bridge

extension DictationEngine: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let payload = (body["payload"] as? String) ?? ""

        switch type {
        case "ready":
            isReady = true
            if wantsCompact { webView.evaluateJavaScript("window.__zrCompact()") }
            onReady?()

        case "compact":
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let w = json["width"] as? Double,
                  let h = json["height"] as? Double else { return }
            onCompactSize?(CGSize(width: w, height: h))

        case "recording":
            // The page confirmed it is really dictating.
            guard state == .starting else { return }
            set(.recording)
            arm(seconds: maxRecordingSeconds) { [weak self] in
                guard let self, self.state == .recording else { return }
                self.stop()
            }

        case "mic-blocked":
            stopWatchdog()
            set(.idle)
            onFailure?(.micBlocked)

        case "start-failed":
            stopWatchdog()
            set(.idle)
            onFailure?(.other(payload))
            logDiagnosis()

        case "transcript":
            stopWatchdog()
            webView.evaluateJavaScript("window.__zrCleanup()")
            set(.idle)
            onTranscript?(payload)

        case "error":
            stopWatchdog()
            set(.idle)
            onFailure?(.other(payload))

        default:
            break
        }
    }
}

// MARK: - Permissions and navigation

extension DictationEngine: WKUIDelegate, WKNavigationDelegate {

    /// Hands the microphone to the page. macOS still gates this on the app's own
    /// microphone grant, which is requested at launch.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?(.other("Page failed to load."))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure?(.other("No connection to ChatGPT."))
    }
}

// MARK: - Login window lifecycle

extension DictationEngine: NSWindowDelegate {
    /// Closing the window must not destroy the web view, it only hides it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideLoginWindow()
        return false
    }
}
