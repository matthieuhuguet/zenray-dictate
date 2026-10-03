import AppKit
import CoreText

// 3 October 2026, 19:55 CEST: register bundled fonts before constructing any native window.
for font in Bundle.main.urls(forResourcesWithExtension:"ttf",subdirectory:"Fonts") ?? [] {
    CTFontManagerRegisterFontsForURL(font as CFURL,.process,nil)
}
let app = NSApplication.shared
// 3 October 2026, 16:09 CEST: AppKit runs this entry point on the main thread.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// A regular app keeps the independent composer visible in the Dock.
app.setActivationPolicy(.regular)
app.run()
