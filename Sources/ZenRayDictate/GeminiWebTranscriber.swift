import AppKit
import WebKit

// 3 October 2026, 15:52 CEST: a private app web session runs Gemini's own microphone flow.
@MainActor
final class GeminiWebTranscriber: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Settings {
        static let url = URL(string: "https://gemini.google.com/app")!
        static let readyTimeout: TimeInterval = 30
        static let responseTimeout: TimeInterval = 45
        static let maximumAudioBytes = 64 * 1024 * 1024
        static let sessionID = UUID(uuidString: "72BB7BB9-9B1C-4DF7-BC76-6F8C4BE422D1")!
    }

    private var webView: WKWebView!
    private var sessionWindow: NSWindow!
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var requestID: String?
    private var timeoutTask: Task<Void, Never>?
    private var resourceError: Error?
    private var finishing = false

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Settings.sessionID)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "dictation")
        do {
            guard let url = Bundle.main.url(forResource: "GeminiBridge", withExtension: "js") else {
                throw TranscriptionError.geminiUnavailable("The Gemini bridge resource is missing. Rebuild ZenRayDictate.")
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } catch { resourceError = error }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        sessionWindow = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sessionWindow.title = "ZenRayDictate · Gemini session"
        sessionWindow.isReleasedWhenClosed = false
        sessionWindow.contentView = webView
        sessionWindow.center()
        webView.load(URLRequest(url: Settings.url))
    }

    func showSession() {
        sessionWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if let resourceError { throw resourceError }
        guard continuation == nil else { throw TranscriptionError.geminiUnavailable("Gemini is already transcribing a recording.") }
        let audio = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        guard !audio.isEmpty, audio.count <= Settings.maximumAudioBytes else {
            throw TranscriptionError.geminiUnavailable("Recording exceeds the Gemini web bridge size limit.")
        }
        let deadline = Date().addingTimeInterval(Settings.readyTimeout)
        var ready = false
        while Date() < deadline {
            if let host = webView.url?.host, host == "accounts.google.com" {
                showSession()
                throw TranscriptionError.geminiUnavailable("Sign in to Google in the ZenRayDictate Gemini session, then retry the saved recording.")
            }
            if !webView.isLoading, webView.url?.host == Settings.url.host,
               let available = try? await webView.evaluateJavaScript("Boolean(window.ZenRayGemini?.ready())"), available as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard ready else {
            showSession()
            throw TranscriptionError.geminiUnavailable("Gemini dictation is unavailable. Sign in or check the Gemini session, then retry.")
        }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            requestID = id
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((Settings.responseTimeout + Double(audio.count) / 32_000) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(TranscriptionError.geminiUnavailable("Gemini dictation timed out; the recording remains available for retry.")))
            }
            let payload: [String: Any] = ["id": id, "audio": audio.base64EncodedString(), "responseTimeoutMs": Int(Settings.responseTimeout * 1000)]
            webView.callAsyncJavaScript("await window.ZenRayGemini.transcribe(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
                if case let .failure(error) = result, self?.requestID == id { self?.finish(.failure(error)) }
            }
        }
    }

    func rewrite(_ text: String, instruction: String, model: String) async throws -> String {
        guard continuation == nil else { throw TranscriptionError.geminiUnavailable("Gemini is busy.") }
        if resourceError != nil { throw resourceError! }
        let deadline = Date().addingTimeInterval(Settings.readyTimeout)
        while webView.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
        let id = UUID().uuidString
        let result: TranscriptionResult = try await withCheckedThrowingContinuation { pending in
            continuation = pending; requestID = id
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                if !Task.isCancelled { self?.finish(.failure(TranscriptionError.geminiUnavailable("Gemini text processing timed out."))) }
            }
            webView.callAsyncJavaScript("await window.ZenRayGemini.rewrite(payload)", arguments: ["payload":["id":id,"text":text,"instruction":instruction,"model":model]], in:nil,in:.page) { [weak self] result in
                if case let .failure(error) = result, self?.requestID == id { self?.finish(.failure(error)) }
            }
        }
        return result.text
    }

    private func finish(_ result: Result<TranscriptionResult, Error>) {
        guard let pending = continuation, !finishing else { return }
        finishing = true
        timeoutTask?.cancel(); timeoutTask = nil
        let complete = { [self] in
            continuation = nil; requestID = nil; finishing = false
            pending.resume(with:result)
        }
        if case .failure = result {
            webView.callAsyncJavaScript("await window.ZenRayGemini?.cancel()",arguments:[:],in:nil,in:.page) { _ in complete() }
        } else { complete() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == Settings.url.host,
              let payload = message.body as? [String: Any], let id = payload["id"] as? String, id == requestID else { return }
        if let error = payload["error"] as? String {
            finish(.failure(TranscriptionError.geminiUnavailable(error)))
        } else if let text = payload["text"] as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.rangeOfCharacter(from: .alphanumerics) != nil else {
                finish(.failure(TranscriptionError.invalidResponse)); return
            }
            finish(.success(TranscriptionResult(text: normalized, provider: "Gemini web dictation")))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(TranscriptionError.geminiUnavailable("Gemini web session stopped; retry the saved recording.")))
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https",
              let host = url.host, host == "gemini.google.com" || host == "accounts.google.com" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 3 October 2026, 15:52 CEST: the bridge supplies saved audio; other media prompts remain user-controlled.
        decisionHandler(origin.host == Settings.url.host && type == .microphone ? .prompt : .deny)
    }
}
