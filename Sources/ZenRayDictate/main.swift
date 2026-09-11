import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A regular app keeps the independent composer visible in the Dock.
app.setActivationPolicy(.regular)
app.run()
