import os

/// Logger with public visibility so messages are not redacted as <private> in Console.app.
private let panelessOSLog = OSLog(subsystem: "com.paneless.app", category: "wm")

func panelessLog(_ message: String) {
    os_log("%{public}s", log: panelessOSLog, type: .default, message)
    // Also write to stderr for easy debugging via Console.app or `log stream`
    fputs("[Paneless] \(message)\n", stderr)
}
