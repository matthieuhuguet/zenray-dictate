import AppKit
import WebKit

// 3 October 2026, 15:52 CEST: a private app web session runs Gemini's own microphone flow.
@MainActor
final class GeminiWebTranscriber: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    enum Settings {
        static let url = URL(string: "https://gemini.google.com/app")!
        static let readyTimeout: TimeInterval = 30
        static let responseTimeout: TimeInterval = 45
        static let maximumAudioBytes = 64 * 1024 * 1024
        static let capsuleWidth: CGFloat = 340
        static let resultWidth: CGFloat = 720
        static let bottomInset: CGFloat = 24
        static let capsuleMinimumHeight: CGFloat = 76
        static let capsuleMaximumHeight: CGFloat = 460
        static let rightInset: CGFloat = 18
        static let fadeDuration: TimeInterval = 0.18
        static let resultFadeDuration: TimeInterval = 0.1
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
    private var liveFinishing = false
    private var composerPresented = false
    private var resultPresented = false
    private var resultTransitioning = false
    private var resultTransitionElapsed: TimeInterval = 0
    private var capturePresentationElapsed: TimeInterval = 0
    private var captureFrameElapsed: TimeInterval = 0
    private var fadeGeneration = 0
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var lastCaptureID: String?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    var onLiveState: ((String) -> Void)?

    // 5 October 2026: auto-reload after network recovery if launched before Wi-Fi connects at login.
    private func scheduleReload(delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            Log.write("Retrying Gemini load after network wait (attempt \(self.retryCount))")
            self.webView.load(URLRequest(url: Settings.url))
        }
    }

    #if DEBUG
    static var verificationScript: String?
    #endif

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Settings.sessionID)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // 4 October 2026: background dictation must keep its event observers and completion timers running.
        configuration.preferences.inactiveSchedulingPolicy = .none
        #if DEBUG
        if let script=Self.verificationScript { configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true)) }
        #endif
        configuration.userContentController.add(self, name: "dictation")
        configuration.userContentController.add(self,name:"composerLayout")
        configuration.userContentController.add(self,name:"liveCapture")
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
        sessionWindow.contentMinSize = NSSize(width:Settings.capsuleWidth,height:Settings.capsuleMinimumHeight)
        sessionWindow.title = "ZenRayDictate · Gemini session"
        sessionWindow.isReleasedWhenClosed = false
        sessionWindow.contentView = webView
        sessionWindow.delegate = self
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.fadeComposer() } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
            if let self,event.window !== self.sessionWindow,event.window?.level != .statusBar { self.fadeComposer() }
            return event
        }
        // 09 October 2026: prepare the private web surface without ordering an invisible window front,
        // preventing WindowServer from keeping a floating auxiliary layer on-screen across Spaces.
        sessionWindow.alphaValue = 0; sessionWindow.ignoresMouseEvents = true
        prepareCompact()
        sessionWindow.orderOut(nil)
        webView.load(URLRequest(url: Settings.url))
    }

    // 3 October 2026, 22:15 CEST: recording stays invisible; only explicit icon clicks reveal the right-side preview.
    private func positionComposer() {
        guard let screen=NSScreen.main else { return }
        let frame=screen.visibleFrame,height=sessionWindow.frame.height
        let origin=resultPresented
            ? NSPoint(x:frame.midX-Settings.resultWidth/2,y:frame.minY+Settings.bottomInset)
            : NSPoint(x:frame.maxX-Settings.capsuleWidth-Settings.rightInset,y:frame.midY-height/2)
        sessionWindow.setFrameOrigin(origin)
    }
    private func prepareCompact() {
        compact=true
        sessionWindow.styleMask=[.borderless,.nonactivatingPanel]
        sessionWindow.backgroundColor = .clear
        sessionWindow.title="ZenRayDictate · Gemini"
        let width=resultPresented ? Settings.resultWidth : Settings.capsuleWidth
        sessionWindow.contentMinSize=NSSize(width:width,height:Settings.capsuleMinimumHeight)
        // 7 October 2026, 11:52 CEST: preserve the prepared DOM geometry when the capsule width is unchanged.
        if sessionWindow.frame.width != width {
            sessionWindow.setContentSize(NSSize(width:width,height:Settings.capsuleMinimumHeight))
        }
        positionComposer()
        webView.evaluateJavaScript("window.ZenRayComposer?.setCompact(true)")
    }
    func showComposer(activate: Bool = true) {
        fadeGeneration += 1;resultTransitioning=false;composerPresented=true
        prepareCompact()
        sessionWindow.ignoresMouseEvents=false;sessionWindow.alphaValue=1
        if activate { sessionWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
        else { sessionWindow.orderFrontRegardless() }
    }
    func toggleComposer() { if composerPresented { fadeComposer() } else { showComposer() } }
    func fadeComposer() {
        // 4 October 2026: recording stays visible until the final transcript is ready.
        guard compact,composerPresented,!liveRecording,!liveStarting else { return }
        composerPresented=false;resultTransitioning=false;fadeGeneration += 1;let generation=fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration=Settings.fadeDuration
            sessionWindow.animator().alphaValue=0
        },completionHandler:{ [weak self] in
            Task { @MainActor in
                guard let self,self.fadeGeneration==generation,!self.composerPresented else { return }
                self.sessionWindow.ignoresMouseEvents = true
                // 09 October 2026: order out the window when hidden so it never stays composited on Spaces.
                self.sessionWindow.orderOut(nil)
            }
        })
    }
    // 4 October 2026: move as soon as capture stops, independently of final transcript stabilization.
    private func transitionToResult() {
        guard compact,composerPresented,!resultPresented,!resultTransitioning else { return }
        resultTransitioning=true;resultTransitionElapsed=0
        fadeGeneration += 1;let generation=fadeGeneration,started=ProcessInfo.processInfo.systemUptime
        NSAnimationContext.runAnimationGroup({ context in
            context.duration=Settings.resultFadeDuration
            sessionWindow.animator().alphaValue=0
        },completionHandler:{ [weak self] in
            Task { @MainActor in
                guard let self,self.fadeGeneration==generation,self.composerPresented else { return }
                self.resultPresented=true;self.prepareCompact();self.resultTransitioning=false
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration=Settings.resultFadeDuration
                    self.sessionWindow.animator().alphaValue=1
                },completionHandler:{ [weak self] in
                    Task { @MainActor in
                        guard let self,self.fadeGeneration==generation else { return }
                        self.resultTransitionElapsed=ProcessInfo.processInfo.systemUptime-started
                        Log.write("Gemini result transition completed in \(self.resultTransitionElapsed) seconds")
                    }
                })
            }
        })
    }
    func windowDidResignKey(_ notification: Notification) { if NSApp.currentEvent?.window?.level != .statusBar { fadeComposer() } }
    private func presentRecording() {
        resultPresented=false
        showComposer(activate:false)
    }
    func pressFn() { toggleLiveMicrophone() }
    func releaseFn() {}
    func fnSpace() { toggleLiveMicrophone() }

    func startLiveMicrophone() {
        guard !liveRecording,!liveStarting,!liveFinishing,continuation==nil else { return }
        // 7 October 2026, 11:55 CEST: measure presentation separately from microphone readiness.
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let physicalPress = FnKeyMonitor.consumePressUptime()
        let presentationStarted = physicalPress.flatMap { receivedAt >= $0 && receivedAt - $0 < 1 ? $0 : nil } ?? receivedAt
        capturePresentationElapsed = 0; captureFrameElapsed = 0
        do { try BuiltinMicrophone.shared.pin() } catch { showLiveError(error);return }
        if webView.url == nil {
            Log.write("Gemini web session not yet loaded; starting load")
            webView.load(URLRequest(url: Settings.url))
        }
        stopRequested=false;liveStarting=true;onLiveState?("starting")
        presentRecording()
        capturePresentationElapsed = ProcessInfo.processInfo.systemUptime - presentationStarted
        let script = """
        try {
            const deadline = Date.now() + 15000;
            while (!window.ZenRayComposer && Date.now() < deadline) {
                await new Promise(r => setTimeout(r, 100));
            }
            if (!window.ZenRayComposer) {
                return { ok: false, error: 'composer_not_loaded' };
            }
            const started = await window.ZenRayComposer.begin();
            return { ok: started !== false };
        } catch (e) {
            return { ok: false, error: e?.message || String(e) };
        }
        """
        // 7 October 2026, 11:56 CEST: paint the prepared capsule before Gemini's click can occupy its main thread.
        webView.callAsyncJavaScript("await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);return true", arguments: [:], in: nil, in: .page) { [weak self] frameResult in
            guard let self, self.liveStarting else { return }
            if case .success = frameResult {
                self.captureFrameElapsed = ProcessInfo.processInfo.systemUptime - presentationStarted
                Log.write("Gemini capture presentation: native=\(self.capturePresentationElapsed), pageFrame=\(self.captureFrameElapsed) seconds")
            }
            self.webView.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page) { [weak self] result in
                guard let self else { return }
                self.liveStarting=false
                switch result {
                case let .success(val):
                    let dict = val as? [String: Any]
                    if dict?["ok"] as? Bool == true {
                        self.liveRecording = true
                        self.onLiveState?("recording")
                        if self.stopRequested { self.stopLiveMicrophone() }
                    } else {
                        self.liveRecording = false
                        let err = dict?["error"] as? String ?? "begin_returned_false"
                        Log.write("Gemini dictation not ready: \(err)")
                        self.onLiveState?("idle")
                        self.fadeComposer()
                        if err == "composer_not_loaded" && self.webView.url == nil {
                            self.webView.load(URLRequest(url: Settings.url))
                        }
                    }
                case let .failure(error):
                    self.liveRecording = false
                    self.showLiveError(error)
                }
            }
        }
    }
    func stopLiveMicrophone() {
        if liveStarting { stopRequested=true;return }
        guard liveRecording,!liveFinishing else { return }
        liveFinishing=true;onLiveState?("finishing")
        let script = """
        try {
            await window.ZenRayComposer?.end();
            return { ok: true };
        } catch (e) {
            return { ok: false, error: e?.message || String(e) };
        }
        """
        webView.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page) { [weak self] result in
            guard let self else { return }
            self.liveRecording=false;self.liveFinishing=false
            if case let .failure(error)=result { self.showLiveError(error) }
        }
    }
    func toggleLiveMicrophone() {
        Log.write("Gemini Fn toggle: recording=\(liveRecording), starting=\(liveStarting), finishing=\(liveFinishing), appActive=\(NSApp.isActive)")
        if liveRecording || liveStarting { stopLiveMicrophone() } else { startLiveMicrophone() }
    }
    func cancelLiveMicrophone() {
        stopRequested=false
        webView.evaluateJavaScript("window.ZenRayComposer?.cancel()")
        liveRecording=false;liveStarting=false;liveFinishing=false;onLiveState?("idle")
        fadeComposer()
        if compact { sessionWindow.orderOut(nil) }
    }
    private func showLiveError(_ error:Error) {
        onLiveState?("error")
        let nsError = error as NSError
        let jsMessage = (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
        Log.write("Gemini live microphone: \(jsMessage)")
        liveRecording = false
        liveStarting = false
        liveFinishing = false
        fadeComposer()
    }

    #if DEBUG
    // 3 October 2026, 22:20 CEST: the verification build substitutes synthetic audio without opening a real microphone.
    func installVerificationAudio(_ audio:Data) async throws {
        // 4 October 2026: await the actual WebKit completion before starting the witness capture.
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            webView.callAsyncJavaScript("window.ZenRayVerificationAudio=audio;return true",arguments:["audio":audio.base64EncodedString()],in:nil,in:.page) { result in
                switch result { case .success: continuation.resume(); case .failure(let error): continuation.resume(throwing:error) }
            }
        }
    }
    func verificationLoseFocus() { sessionWindow.resignKey();NSApp.deactivate();windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:sessionWindow)) }
    func verificationState() async throws -> [String:Any] {
        var result=(try await webView.evaluateJavaScript("({placeholderSuppressed:(()=>{const e=document.querySelector('.ql-editor');return !!e&&getComputedStyle(e,'::before').content==='none';})(),ready:!!window.ZenRayComposer&&!!window.ZenRayGemini?.ready(),nativeWaveform:!!document.querySelector('butterfly-wave-view canvas'),draft:document.querySelector('[role=\"textbox\"][contenteditable=\"true\"]')?.innerText||''})")) as? [String:Any] ?? [:]
        result["capturePresentationElapsed"]=capturePresentationElapsed;result["captureFrameElapsed"]=captureFrameElapsed;result["transitionElapsed"]=resultTransitionElapsed;result["appActive"]=NSApp.isActive;result["presented"]=composerPresented;result["alpha"]=Double(sessionWindow.alphaValue)
        result["recording"]=liveRecording;result["starting"]=liveStarting;result["finishing"]=liveFinishing
        result["width"]=Double(sessionWindow.frame.width)
        result["right"]=Double(sessionWindow.frame.maxX)
        result["screenRight"]=Double(NSScreen.main?.visibleFrame.maxX ?? 0)
        result["bottom"]=Double(sessionWindow.frame.minY);result["screenBottom"]=Double(NSScreen.main?.visibleFrame.minY ?? 0)
        result["center"]=Double(sessionWindow.frame.midX);result["screenCenter"]=Double(NSScreen.main?.visibleFrame.midX ?? 0)
        return result
    }
    #endif

    func showSession() {
        fadeGeneration += 1;resultTransitioning=false;composerPresented=true
        sessionWindow.alphaValue=1;sessionWindow.ignoresMouseEvents=false
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
            webView.callAsyncJavaScript("await window.ZenRayComposer?.cancel();await window.ZenRayGemini?.cancel();return true;",arguments:[:],in:nil,in:.page) { _ in complete() }
        } else { complete() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "liveCapture" {
            guard message.frameInfo.isMainFrame,message.frameInfo.securityOrigin.host==Settings.url.host,continuation==nil,
                  let payload=message.body as? [String:Any],let state=payload["state"] as? String else { return }
            if state=="recording" { liveRecording=true;presentRecording();onLiveState?(state);return }
            if state=="finishing" { liveRecording=false;liveFinishing=true;onLiveState?(state);transitionToResult();return }
            if state=="error" { liveRecording=false;liveStarting=false;liveFinishing=false;showLiveError(TranscriptionError.geminiUnavailable(payload["error"] as? String ?? "Gemini capture failed."));return }
            if state=="finished" {
                liveRecording=false;liveFinishing=false
                if let id=payload["id"] as? String,id != lastCaptureID {
                    lastCaptureID=id
                    let raw=(payload["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                    if !raw.isEmpty {
                        let library=DictationLibrary.shared,text=library.normalize(raw)
                        let clipboard=NSPasteboard.general
                        clipboard.clearContents()
                        if !clipboard.setString(text,forType:.string) { showLiveError(TranscriptionError.geminiUnavailable("Clipboard write failed; the transcript remains in Gemini."));return }
                        do { try library.record(raw:raw,text:text,provider:"Gemini live dictation",mode:"verbatim",application:"Clipboard",audioURL:nil,inserted:false) }
                        catch { showLiveError(error);return }
                        Log.write("Gemini capture copied automatically: \(text.count) characters")
                    }
                }
            }
            onLiveState?("idle")
            if state=="finished",let text=payload["text"] as? String,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                // 4 October 2026: completed text stays at the bottom center until an outside click.
                transitionToResult()
            } else { fadeComposer() }
            return
        }
        if message.name == "composerLayout" {
            guard compact,!resultTransitioning, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == Settings.url.host,
                  let payload=message.body as? [String:Any],let height=payload["height"] as? Double,height.isFinite else { return }
            let size=NSSize(width:resultPresented ? Settings.resultWidth : Settings.capsuleWidth,height:min(Settings.capsuleMaximumHeight,max(Settings.capsuleMinimumHeight,height)))
            sessionWindow.setContentSize(size)
            positionComposer()
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
        retryCount = 0
        retryTask?.cancel()
        retryTask = nil
        webView.evaluateJavaScript("window.ZenRayComposer?.setCompact(\(compact ? "true" : "false"))")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("Gemini provisional navigation failed: \(error.localizedDescription)")
        finish(.failure(error))
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            retryCount += 1
            let delay = min(30.0, pow(2.0, Double(min(retryCount, 4))))
            scheduleReload(delay: delay)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(TranscriptionError.geminiUnavailable("Gemini web session stopped; retry the saved recording.")))
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https", let host = url.host else {
            decisionHandler(.cancel)
            return
        }
        let isGoogle = host == "gemini.google.com" || host.hasSuffix(".google.com") || host.hasSuffix(".google.fr") || host.hasSuffix(".gstatic.com") || host.hasSuffix(".googleapis.com") || host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".youtube.com")
        if !isGoogle {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 4 October 2026: grant microphone permission directly to Gemini so the website never prompts the user again.
        guard (origin.host == Settings.url.host || origin.host.hasSuffix(".google.com")), type == .microphone else {
            decisionHandler(.deny)
            return
        }
        do {
            try BuiltinMicrophone.shared.pin()
            decisionHandler(.grant)
        } catch {
            showLiveError(error)
            decisionHandler(.deny)
        }
    }
}

// 3 October 2026, 21:45 CEST: borderless composition still accepts keyboard focus when explicitly clicked.
private final class GeminiComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
