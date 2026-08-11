import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A regular app, so it gets a Dock icon: clicking it is a way in that does
// not depend on a crowded menu bar or on Fn.
app.setActivationPolicy(.regular)
app.run()
