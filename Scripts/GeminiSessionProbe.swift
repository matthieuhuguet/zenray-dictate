import AppKit
import WebKit

// 3 October 2026, 16:00 CEST: inspect only the app's dedicated session, never the personal browser.
final class Probe: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var web: WKWebView!
    var window: NSWindow!
    var timer: Timer?
    var formatted = false
    func run() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "72BB7BB9-9B1C-4DF7-BC76-6F8C4BE422D1")!)
        if CommandLine.arguments.count > 1 {
            let source = try! String(contentsOfFile: "Sources/ZenRayDictate/Resources/GeminiBridge.js", encoding:.utf8)
            configuration.userContentController.add(self, name: "dictation")
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            if ["--inspect","--waveform"].contains(CommandLine.arguments[1]) {
                let composer = try! String(contentsOfFile:"Sources/ZenRayDictate/Resources/GeminiComposer.js",encoding:.utf8)
                configuration.userContentController.addUserScript(WKUserScript(source:composer,injectionTime:.atDocumentStart,forMainFrameOnly:true))
            }
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ZenRayDictate · Gemini connection"
        window.contentView = web
        web.load(URLRequest(url: URL(string: "https://gemini.google.com/app")!))
        Timer.scheduledTimer(withTimeInterval:120,repeats:false) { _ in print("Probe timed out"); fflush(stdout); exit(1) }
        var sent = false
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return }
            self.web.evaluateJavaScript("Boolean(window.ZenRayGemini?.ready())") { value,error in
                guard value as? Bool == true, !sent, CommandLine.arguments.count > 1 else { return }
                sent = true; timer.invalidate()
                // 3 October 2026, 21:32 CEST: inspect only the composer structure, excluding chat contents.
                if CommandLine.arguments[1] == "--waveform" {
                    self.window.orderFrontRegardless()
                    let audio = try! Data(contentsOf:URL(fileURLWithPath:"/Users/zenray/.claude/tmp/tmp-zenray-dictate/GeminiWitness.wav"))
                    self.web.callAsyncJavaScript("window.ZenRayComposer.setCompact(true);window.ZenRayGemini.transcribe(payload);await new Promise(r=>setTimeout(r,900));const root=document.querySelector('input-container');return JSON.stringify({state:window.ZenRayComposer.state(),footerHidden:getComputedStyle(root.querySelector('hallucination-disclaimer')).display==='none',capsuleHeight:root.querySelector('.input-area').getBoundingClientRect().height,recordingElements:[...root.querySelectorAll('*')].filter(e=>/wave|speech|audio|record|listening|animation/i.test(e.tagName+' '+e.className)).map(e=>({tag:e.tagName,classes:e.className,height:e.getBoundingClientRect().height})),addedCanvas:!!root.querySelector('.zenray-waveform')})",arguments:["payload":["id":"waveform","audio":audio.base64EncodedString(),"responseTimeoutMs":45000]],in:nil,in:.page) { result in
                        switch result { case .success(let value): print(value);fflush(stdout); case .failure(let error):print(error);fflush(stdout);exit(1) }
                    }
                    return
                }
                if CommandLine.arguments[1] == "--inspect" {
                    self.web.evaluateJavaScript("window.ZenRayComposer.setCompact(true); JSON.stringify({state:window.ZenRayComposer.state(),footer:(()=>{let e=document.querySelector('input-container a[href*=\"policies.google.com\"]');let a=[];while(e&&a.length<6){a.push({tag:e.tagName,classes:e.className});e=e.parentElement;}return a;})(),structure:(()=>{let e=document.querySelector('[role= textbox][contenteditable=true]');let a=[];while(e&&a.length<12){a.push({tag:e.tagName,classes:e.className,height:e.getBoundingClientRect().height});e=e.parentElement;}return a;})()})") { value,error in print(value ?? error as Any); fflush(stdout); exit(error == nil ? 0 : 1) }
                    return
                }
                if CommandLine.arguments[1] == "--rewrite" {
                    self.web.callAsyncJavaScript("await window.ZenRayGemini.rewrite(payload)",arguments:["payload":["id":"probe","instruction":"Correct only punctuation. Return only the corrected text.","text":"Bonjour ceci est un test","model":"Flash"]],in:nil,in:.page) { result in print(result); fflush(stdout) }
                    return
                }
                let audio = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
                self.web.callAsyncJavaScript("await window.ZenRayGemini.transcribe(payload)", arguments: ["payload": ["id":"probe", "audio":audio.base64EncodedString(), "responseTimeoutMs":45000]], in:nil, in:.page) { result in print(result); fflush(stdout) }
            }
        }

    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print(message.body); fflush(stdout)
        if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "--flow", !formatted, let payload = message.body as? [String:Any], let text = payload["text"] as? String {
            formatted = true
            web.callAsyncJavaScript("await window.ZenRayGemini.rewrite(payload)",arguments:["payload":["id":"format","instruction":"Correct only punctuation. Preserve vocabulary. Return only the corrected text.","text":text,"model":"Flash"]],in:nil,in:.page) { result in if case .failure = result { print(result); exit(1) } }
            return
        }
        if let payload = message.body as? [String:Any], payload["error"] != nil { exit(1) }
        NSApp.terminate(nil)

    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("Loaded",webView.url?.host ?? "unknown");fflush(stdout)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
probe.run()
app.run()
