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
        static let capsuleWidth: CGFloat = 720
        static let capsuleMinimumHeight: CGFloat = 76
        static let capsuleMaximumHeight: CGFloat = 250
        static let sessionID = UUID(uuidString: "72BB7BB9-9B1C-4DF7-BC76-6F8C4BE422D1")!
    }

    private var webView: WKWebView!
    private var sessionWindow: NSWindow!
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var requestID: String?
    private var timeoutTask: Task<Void, Never>?
    private var resourceError: Error?
    private var finishing = false
    private var compact = true
    private var liveRecording = false
    private var liveStarting = false
    private var stopRequested = false
    private var handsFree = false
    private var lastFnPress: Date?
    private var releaseTask: Task<Void,Never>?

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Settings.sessionID)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "dictation")
        configuration.userContentController.add(self,name:"composerLayout")
        do {
            guard let url = Bundle.main.url(forResource: "GeminiBridge", withExtension: "js") else {
                throw TranscriptionError.geminiUnavailable("The Gemini bridge resource is missing. Rebuild ZenRayDictate.")
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            guard let composerURL = Bundle.main.url(forResource: "GeminiComposer", withExtension: "js") else { throw TranscriptionError.geminiUnavailable("The Gemini composer resource is missing.") }
            configuration.userContentController.addUserScript(WKUserScript(source: try String(contentsOf:composerURL,encoding:.utf8), injectionTime:.atDocumentStart,forMainFrameOnly:true))
        } catch { resourceError = error }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        sessionWindow = GeminiComposerPanel(contentRect:NSRect(x:0,y:0,width:Settings.capsuleWidth,height:Settings.capsuleMinimumHeight),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        // 3 October 2026, 21:42 CEST: the transparent nonactivating panel contains only the website capsule.
        sessionWindow.isOpaque = false
        sessionWindow.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.setValue(false,forKey:"drawsBackground")
        sessionWindow.hasShadow = true
        sessionWindow.level = .floating
        (sessionWindow as? NSPanel)?.hidesOnDeactivate = false
        sessionWindow.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        sessionWindow.contentMinSize = NSSize(width:520,height:Settings.capsuleMinimumHeight)
        sessionWindow.title = "ZenRayDictate · Gemini session"
        sessionWindow.isReleasedWhenClosed = false
        sessionWindow.contentView = webView
        sessionWindow.center()
        webView.load(URLRequest(url: Settings.url))
    }

    // 3 October 2026, 21:35 CEST: the main window contains Gemini's live DOM and microphone.
    func showComposer(activate: Bool = true) {
        compact = true
        webView.evaluateJavaScript("window.ZenRayComposer?.setCompact(true)")
        sessionWindow.title = "ZenRayDictate · Gemini"
        sessionWindow.styleMask = [.borderless,.nonactivatingPanel]
        sessionWindow.backgroundColor = .clear
        sessionWindow.setContentSize(NSSize(width:Settings.capsuleWidth,height:Settings.capsuleMinimumHeight))
        if let screen = NSScreen.main { let frame=screen.visibleFrame; sessionWindow.setFrameOrigin(NSPoint(x:frame.midX-Settings.capsuleWidth/2,y:frame.minY+22)) }
        if activate { sessionWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
        else { sessionWindow.orderFrontRegardless() }
    }

    // 3 October 2026, 21:46 CEST: hold and double-press operate the website microphone directly.
    func pressFn() {
        releaseTask?.cancel()
        if liveRecording || liveStarting {
            if let lastFnPress,Date().timeIntervalSince(lastFnPress)<DictationLibrary.shared.document.preferences.doublePressInterval { handsFree=true; return }
            if handsFree { handsFree=false; stopLiveMicrophone(); return }
        }
        lastFnPress=Date(); handsFree=false; startLiveMicrophone()
    }
    func releaseFn() {
        guard !handsFree else { return }
        releaseTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:UInt64(DictationLibrary.shared.document.preferences.doublePressInterval*1_000_000_000))
            if !Task.isCancelled { self?.stopLiveMicrophone() }
        }
    }
    func fnSpace() { releaseTask?.cancel(); if liveRecording || liveStarting { handsFree=true } else { handsFree=true;startLiveMicrophone() } }

    func startLiveMicrophone() {
        guard !liveRecording, !liveStarting, continuation == nil else { return }
        do { try BuiltinMicrophone.shared.pin() } catch { showLiveError(error); return }
        stopRequested = false; liveStarting = true
        showComposer(activate:false)
        webView.evaluateJavaScript("window.ZenRayComposer.microphone(false)") { [weak self] _,error in
            guard let self else { return }
            self.liveStarting = false
            if let error { self.showLiveError(error); return }
            self.liveRecording = true
            if self.stopRequested { self.stopLiveMicrophone() }
        }
    }

    func stopLiveMicrophone() {
        if liveStarting { stopRequested = true; return }
        guard liveRecording else { return }
        webView.evaluateJavaScript("window.ZenRayComposer.microphone(true)") { [weak self] _,error in
            self?.liveRecording = false
            if let error { self?.showLiveError(error) }
        }
    }

    func toggleLiveMicrophone() { releaseTask?.cancel(); handsFree=true; if liveRecording || liveStarting { stopLiveMicrophone() } else { startLiveMicrophone() } }
    func cancelLiveMicrophone() { releaseTask?.cancel(); stopLiveMicrophone(); if compact { sessionWindow.orderOut(nil) } }
    private func showLiveError(_ error:Error) {
        Log.write("Gemini live microphone: \(error.localizedDescription)")
        let alert = NSAlert(); alert.messageText = "Gemini microphone unavailable"; alert.informativeText = error.localizedDescription + " Open Gemini session from the menu to check access."; alert.beginSheetModal(for:sessionWindow)
    }

    func showSession() {
        compact = false
        sessionWindow.styleMask = [.titled,.closable,.resizable,.nonactivatingPanel]
        sessionWindow.backgroundColor = .windowBackgroundColor
        webView.evaluateJavaScript("window.ZenRayComposer?.setCompact(false)")
        sessionWindow.title = "ZenRayDictate · Gemini session"
        sessionWindow.setContentSize(NSSize(width:1000,height:740)); sessionWindow.center()
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
        if message.name == "composerLayout" {
            guard compact, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == Settings.url.host,
                  let payload=message.body as? [String:Any],let height=payload["height"] as? Double,height.isFinite else { return }
            let old=sessionWindow.frame
            let size=NSSize(width:Settings.capsuleWidth,height:min(Settings.capsuleMaximumHeight,max(Settings.capsuleMinimumHeight,height)))
            sessionWindow.setFrame(NSRect(origin:old.origin,size:size),display:true)
            return
        }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.ZenRayComposer?.setCompact(\(compact ? "true" : "false"))")
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
        guard origin.host == Settings.url.host,type == .microphone else { decisionHandler(.deny); return }
        do { try BuiltinMicrophone.shared.pin(); decisionHandler(.prompt) }
        catch { showLiveError(error); decisionHandler(.deny) }
    }
}

// 3 October 2026, 21:45 CEST: borderless composition still accepts keyboard focus when explicitly clicked.
private final class GeminiComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
