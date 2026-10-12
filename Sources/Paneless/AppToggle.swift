import AppKit

/// What one press of a `toggle_app` binding does: the app in front hides, windows and all;
/// otherwise it launches, or comes back from hidden or from behind. Opening a running app
/// sends it a reopen, so Terminal with every window closed gets a fresh one. Whether its
/// windows float in the middle is up to the float rule, as for any other app.
enum AppToggle: Equatable {
    case hide
    case open

    static func step(isFrontmost: Bool) -> AppToggle {
        isFrontmost ? .hide : .open
    }

    /// Where the app lives, named as in the config: a bundle ID, or the app's name as it
    /// appears in the standard application folders.
    static func applicationURL(for app: String) -> URL? {
        if app.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            return url
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        return folders
            .map { URL(fileURLWithPath: $0).appendingPathComponent(app + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
