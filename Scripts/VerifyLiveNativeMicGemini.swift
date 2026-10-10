import AppKit
import Foundation

// 10 October 2026: end-to-end live verification of NativeMicrophoneBridge (input-only AUHAL)
// + window.ZenRayNativeMic.pushPCM16 + GeminiWebTranscriber on both MacBook Pro and iPhone Continuity microphones.
@main struct VerifyLiveNativeMicGemini {
    @MainActor static func main() {
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.zenray.dictate" }) else {
            fputs("Verification refused: ZenRayDictate is already running.\n", stderr)
            exit(2)
        }
        ProcessInfo.processInfo.disableAutomaticTermination("Live NativeMic verification in progress")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApplication.shared.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                let wavURL = URL(fileURLWithPath: CommandLine.arguments[1])
                let wavData = try Data(contentsOf: wavURL)
                let pcmData = wavData.count > 44 ? wavData.subdata(in: 44..<wavData.count) : wavData
                let samples: [Int16] = pcmData.withUnsafeBytes { rawBuf in
                    Array(rawBuf.bindMemory(to: Int16.self))
                }
                // Prepend 0.25s silence (4000 samples at 16 kHz) so Gemini's recognizer settles before the first word
                NativeMicrophoneBridge.verificationSamples = Array(repeating: Int16(0), count: 4000) + samples

                var states: [String] = []
                let web = GeminiWebTranscriber()
                web.onLiveState = { states.append($0) }

                let deadline = Date().addingTimeInterval(35)
                while Date() < deadline {
                    if let state = try? await web.verificationState(), state["ready"] as? Bool == true {
                        break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }

                let manager = MicrophoneManager.shared
                manager.refreshDevices()
                guard let builtInID = manager.builtInDeviceID() else {
                    throw NSError(domain: "LiveNativeMic", code: 1, userInfo: [NSLocalizedDescriptionKey: "MacBook Pro Microphone not found"])
                }
                let continuityID = manager.continuityDeviceID()

                var testTargets: [(String, UInt32)] = [("MacBook Pro Microphone", builtInID)]
                if let cID = continuityID {
                    testTargets.append(("iPhone Continuity Microphone", cID))
                }

                let clipboard = NSPasteboard.general
                let savedClipboard = clipboard.string(forType: .string)
                var results: [[String: Any]] = []

                for (label, targetID) in testTargets {
                    states.removeAll()
                    manager.switchToDevice(id: targetID)
                    guard manager.activeDevice?.id == targetID else {
                        throw NSError(domain: "LiveNativeMic", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to switch to \(label)"])
                    }

                    web.pressFn()
                    let startDeadline = Date().addingTimeInterval(15)
                    while Date() < startDeadline {
                        let st = try await web.verificationState()
                        if st["recording"] as? Bool == true, st["starting"] as? Bool == false {
                            break
                        }
                        if states.contains("error") {
                            throw NSError(domain: "LiveNativeMic", code: 3, userInfo: [NSLocalizedDescriptionKey: "Gemini failed to start on \(label)"])
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }

                    // Let the real hardware AUHAL callback on targetID clock the 16 kHz PCM16 chunks into Gemini for 4.2s
                    try await Task.sleep(nanoseconds: 4_200_000_000)
                    let midState = try await web.verificationState()
                    let hwChunks = midState["nativeMicChunks"] as? Int ?? 0
                    let nativeActive = midState["nativeMicActive"] as? Bool ?? false
                    let waveform = midState["nativeWaveform"] as? Bool ?? false

                    guard nativeActive, hwChunks >= 50, waveform else {
                        throw NSError(domain: "LiveNativeMic", code: 4, userInfo: [NSLocalizedDescriptionKey: "NativeMic not streaming on \(label): active=\(nativeActive), chunks=\(hwChunks), waveform=\(waveform)"])
                    }

                    // Stop capture with second Fn press
                    web.pressFn()
                    let finishDeadline = Date().addingTimeInterval(25)
                    while Date() < finishDeadline {
                        let st = try await web.verificationState()
                        if st["recording"] as? Bool == false, st["finishing"] as? Bool == false, states.contains("idle") {
                            break
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }

                    let copied = clipboard.string(forType: .string) ?? ""
                    guard copied.lowercased().contains("bonjour"), !states.contains("error") else {
                        throw NSError(domain: "LiveNativeMic", code: 5, userInfo: [NSLocalizedDescriptionKey: "Gemini did not transcribe spoken audio on \(label): copied='\(copied)', states=\(states)"])
                    }
                    web.fadeComposer()
                    try await Task.sleep(nanoseconds: 300_000_000)

                    results.append([
                        "device": label,
                        "deviceID": targetID,
                        "nativeMicActive": nativeActive,
                        "hardwareAUHALChunksClocked": hwChunks,
                        "nativeWaveform": waveform,
                        "transcribedText": copied
                    ])
                }

                manager.switchToDevice(id: builtInID)
                if let savedClipboard {
                    clipboard.clearContents()
                    clipboard.setString(savedClipboard, forType: .string)
                }

                let proof: [String: Any] = [
                    "date": "10 October 2026",
                    "results": results
                ]
                let data = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
                print(String(data: data, encoding: .utf8)!)
                fflush(stdout)
                exit(0)
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}
