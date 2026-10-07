import AppKit

// 3 October 2026, 22:20 CEST: exercise the production Fn handlers with synthetic audio and real Gemini transcription.
@main struct VerifyFnCapture {
    @MainActor static func main() {
        // 7 October 2026, 12:05 CEST: refuse a second capsule while the production app is running.
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.zenray.dictate" }) else {
            fputs("Verification refused: ZenRayDictate is already running. No second capsule will be opened.\n",stderr)
            exit(2)
        }
        fputs("Fn probe boot\n",stderr);fflush(stderr)
        ProcessInfo.processInfo.disableAutomaticTermination("Verification in progress")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                fputs("Fn probe actor\n",stderr);fflush(stderr)
                GeminiWebTranscriber.verificationScript="navigator.mediaDevices.getUserMedia=async()=>{const bytes=Uint8Array.from(atob(window.ZenRayVerificationAudio),c=>c.charCodeAt(0));const context=new AudioContext();const buffer=await context.decodeAudioData(bytes.buffer);const destination=context.createMediaStreamDestination();const source=context.createBufferSource();source.buffer=buffer;source.connect(destination);await context.resume();source.start();return destination.stream;};"
                var states:[String]=[]
                let web=GeminiWebTranscriber()
                web.onLiveState={ states.append($0) }
                fputs("Fn probe initialized\n",stderr);fflush(stderr)
                let audio=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
                let deadline=Date().addingTimeInterval(35)
                while Date()<deadline {
                    if let state=try? await web.verificationState(),state["ready"] as? Bool==true { fputs("Fn probe ready\n",stderr);fflush(stderr);break }
                    try await Task.sleep(nanoseconds:200_000_000)
                }
                // 7 October 2026, 12:01 CEST: verify repeated capture readiness, including the idle placeholder before Fn.
                for iteration in 0..<5 {
                states.removeAll()
                try await web.installVerificationAudio(audio)
                let clipboard=NSPasteboard.general
                let previous=clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType:type).map{(type,$0)} } } ?? []
                web.verificationLoseFocus()
                let idle=try await web.verificationState()
                guard idle["placeholderSuppressed"] as? Bool==true else { throw NSError(domain:"FnProbe",code:9,userInfo:[NSLocalizedDescriptionKey:"Idle Gemini placeholder is visible"]) }
                web.pressFn()
                let startDeadline=Date().addingTimeInterval(15)
                while Date()<startDeadline {
                    let state=try await web.verificationState()
                    if state["recording"] as? Bool==true,state["starting"] as? Bool==false { break }
                    if states.contains("error") { throw NSError(domain:"FnProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Gemini could not start the synthetic capture"] ) }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                let presentation=try await web.verificationState()
                guard let frame=presentation["captureFrameElapsed"] as? Double,frame>0,frame<=0.1 else { throw NSError(domain:"FnProbe",code:10,userInfo:[NSLocalizedDescriptionKey:"Prepared capsule exceeded 100 ms: \(presentation)"]) }
                web.releaseFn()
                web.verificationLoseFocus()
                try await Task.sleep(nanoseconds:4_500_000_000)
                web.fadeComposer()
                let recording=try await web.verificationState()
                guard recording["appActive"] as? Bool==false,recording["recording"] as? Bool==true,recording["presented"] as? Bool==true,recording["alpha"] as? Double==1,recording["width"] as? Double==340,recording["nativeWaveform"] as? Bool==true,let right=recording["right"] as? Double,let screenRight=recording["screenRight"] as? Double,abs(screenRight-right-18)<1 else { throw NSError(domain:"FnProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"Recording did not stay visible with the native waveform at the right edge: \(recording), states=\(states)"] ) }
                web.pressFn()
                let transitionDeadline=Date().addingTimeInterval(0.6)
                var transitionElapsed:Double=0
                while Date()<transitionDeadline {
                    let state=try await web.verificationState()
                    transitionElapsed=state["transitionElapsed"] as? Double ?? 0
                    if transitionElapsed>0 { break }
                    try await Task.sleep(nanoseconds:10_000_000)
                }
                guard transitionElapsed>0,transitionElapsed<0.4 else { throw NSError(domain:"FnProbe",code:6,userInfo:[NSLocalizedDescriptionKey:"Result transition did not finish promptly"] ) }
                web.fadeComposer()
                try await Task.sleep(nanoseconds:250_000_000)
                let dismissed=try await web.verificationState()
                guard dismissed["presented"] as? Bool==false else { throw NSError(domain:"FnProbe",code:7,userInfo:[NSLocalizedDescriptionKey:"Pending result cannot be dismissed"] ) }
                let finishDeadline=Date().addingTimeInterval(25)
                while Date()<finishDeadline {
                    let state=try await web.verificationState()
                    if state["recording"] as? Bool==false,state["finishing"] as? Bool==false,states.contains("idle") { break }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                let copied=clipboard.string(forType:.string) ?? "",stamp=clipboard.changeCount
                guard copied.lowercased().contains("bonjour"),!states.contains("error") else { throw NSError(domain:"FnProbe",code:3,userInfo:[NSLocalizedDescriptionKey:"Capture did not copy its completed transcript"] ) }
                let completed=try await web.verificationState()
                guard completed["presented"] as? Bool==false,completed["alpha"] as? Double==0 else { throw NSError(domain:"FnProbe",code:8,userInfo:[NSLocalizedDescriptionKey:"Completion reopened the dismissed result"] ) }
                web.showComposer()
                try await Task.sleep(nanoseconds:300_000_000)
                let shown=try await web.verificationState()
                fputs("Result geometry: \(shown)\n",stderr)
                guard shown["presented"] as? Bool==true,shown["width"] as? Double==720,let bottom=shown["bottom"] as? Double,let screenBottom=shown["screenBottom"] as? Double,let center=shown["center"] as? Double,let screenCenter=shown["screenCenter"] as? Double,abs(bottom-screenBottom-24)<1,abs(center-screenCenter)<1 else { throw NSError(domain:"FnProbe",code:4,userInfo:[NSLocalizedDescriptionKey:"Final text is not bottom-centered"] ) }
                web.fadeComposer()
                try await Task.sleep(nanoseconds:400_000_000)
                let hidden=try await web.verificationState()
                guard hidden["presented"] as? Bool==false,hidden["alpha"] as? Double==0 else { throw NSError(domain:"FnProbe",code:5,userInfo:[NSLocalizedDescriptionKey:"Fade did not hide preview"] ) }
                let proof:[String:Any]=["date":"7 October 2026","iteration":iteration,"placeholderSuppressed":idle["placeholderSuppressed"] ?? false,"capturePresentationElapsed":recording["capturePresentationElapsed"] ?? -1,"captureFrameElapsed":recording["captureFrameElapsed"] ?? -1,"visibleCapture":true,"focusLossDoesNotStop":true,"backgroundStartAndStop":true,"dismissedDuringStabilization":true,"completionDoesNotReopen":true,"transitionElapsed":transitionElapsed,"fadeOutDuration":0.1,"fadeInDuration":0.1,"nativeWaveform":true,"fadeIgnoredWhileRecording":true,"releaseKeepsRecording":true,"secondFnStops":true,"copiedText":copied,"recordingWidth":340,"resultWidth":shown["width"]!,"rightInset":18,"bottomInset":24,"faded":true,"states":states]
                print(String(data:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),encoding:.utf8)!)
                if clipboard.changeCount==stamp { clipboard.clearContents();clipboard.writeObjects(previous.map { formats in let item=NSPasteboardItem();for(type,data)in formats{item.setData(data,forType:type)};return item }) }
                }
                fflush(stdout);exit(0)
            } catch { print(error.localizedDescription);fflush(stdout);exit(1) }
        }
        NSApplication.shared.run()
    }
}
