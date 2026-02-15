import os

/// Logger with public visibility so messages are not redacted as <private> in Console.app.
private let spaceyOSLog = OSLog(subsystem: "com.spacey.app", category: "wm")

func spaceyLog(_ message: String) {
    os_log("%{public}s", log: spaceyOSLog, type: .default, message)
}
