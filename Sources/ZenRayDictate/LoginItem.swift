import ServiceManagement

/// Launch at login, via the modern SMAppService API (macOS 13+).
///
/// This registers the running .app bundle itself, at its current path, so the
/// app must stay where it is for the login item to keep finding it.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Safe to call every launch: registering an already registered app is a
    /// no-op, not an error.
    static func enable() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.write("registered as a login item")
        } catch {
            Log.write("could not register as a login item: \(error.localizedDescription)")
        }
    }

    static func disable() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
            Log.write("removed from login items")
        } catch {
            Log.write("could not remove from login items: \(error.localizedDescription)")
        }
    }
}
