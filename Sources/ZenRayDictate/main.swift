import AppKit
import CoreText

// 25 October 2026, 19:20 CEST: verification entry point, `ZenRayDictate --transcribe <audio file>` runs the
// configured Claude engine headless and prints the text, so the engine is testable without the interface.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let done = DispatchSemaphore(value: 0); var code: Int32 = 0
    Task.detached {
        do { let result = try await ClaudeVoiceTranscriber().transcribe(audioURL: url); print("\(result.provider)\t\(result.text)") }
        catch { FileHandle.standardError.write(Data("ERROR \(error.localizedDescription)\n".utf8)); code = 1 }
        done.signal()
    }
    done.wait(); exit(code)
}

// 25 October 2026, 21:05 CEST: `ZenRayDictate --overlay-preview` shows the B1 capsule (4 s) then the result card (6 s)
// with synthetic levels, and prints the window numbers so the panels can be captured with screencapture -l.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--overlay-preview" {
    let previewApp = NSApplication.shared
    previewApp.setActivationPolicy(.accessory)
    for font in (Bundle.main.urls(forResourcesWithExtension:"ttf",subdirectory:"Fonts") ?? []) + (Bundle.main.urls(forResourcesWithExtension:"otf",subdirectory:"Fonts") ?? []) {
        CTFontManagerRegisterFontsForURL(font as CFURL,.process,nil)
    }
    MainActor.assumeIsolated {
        let overlay = ClaudeOverlay()
        overlay.showRecording()
        var phase = 0.0
        let levels = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            phase += 0.35; MainActor.assumeIsolated { overlay.add(level: Float(0.12 + 0.3 * abs(sin(phase) * sin(phase * 0.37)))) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { print("capsule window \(NSApp.windows.filter { $0.isVisible }.map(\.windowNumber))"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            levels.invalidate()
            MainActor.assumeIsolated { overlay.showResult("Bonjour, je teste la dictée de Claude avec Houdini et Unreal Engine.", insertable: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("card window \(NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0.5 }.map(\.windowNumber))"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    }
    previewApp.run()
}

// 25 October 2026, 21:50 CEST: `ZenRayDictate --live-latency <audio file>` streams the file through the live session at
// real-time pace, as a voice would be, then prints how long after the stop the live text and the final text were ready.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live-latency" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let done = DispatchSemaphore(value: 0); var code: Int32 = 0
    Task.detached {
        do {
            let pcm = try ClaudeVoiceTranscriber.pcm16(from: url)
            _ = try ClaudeVoiceTranscriber.token()
            let session = try ClaudeLiveSession(preferences: DictationLibrary.shared.document.preferences)
            var offset = 0
            while offset < pcm.count { let end = min(offset + 1_280, pcm.count); session.feed(pcm.subdata(in: offset..<end)); offset = end; try await Task.sleep(nanoseconds: 40_000_000) }
            let stop = Date()
            let early = await session.liveText()
            let earlyMs = Int(Date().timeIntervalSince(stop) * 1000)
            let result = try await session.finish()
            print("live text after \(earlyMs) ms: \(early)")
            print("final text after \(Int(Date().timeIntervalSince(stop) * 1000)) ms: \(result.text)")
        } catch { FileHandle.standardError.write(Data("ERROR \(error.localizedDescription)\n".utf8)); code = 1 }
        done.signal()
    }
    done.wait(); exit(code)
}

// 5 October 2026: Single-instance guard prevents duplicate WebKit data store conflicts.
let bundleID = Bundle.main.bundleIdentifier ?? "com.zenray.dictate"
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
if let existing = runningApps.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate()
    exit(0)
}

// 3 October 2026, 19:55 CEST: register bundled fonts before constructing any native window.
for font in (Bundle.main.urls(forResourcesWithExtension:"ttf",subdirectory:"Fonts") ?? []) + (Bundle.main.urls(forResourcesWithExtension:"otf",subdirectory:"Fonts") ?? []) {
    CTFontManagerRegisterFontsForURL(font as CFURL,.process,nil)
}
let app = NSApplication.shared
// 3 October 2026, 16:09 CEST: AppKit runs this entry point on the main thread.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// A regular app keeps the independent composer visible in the Dock.
app.setActivationPolicy(.regular)
app.run()
