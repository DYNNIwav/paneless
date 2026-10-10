import Foundation

/// Apps another app has asked Paneless to float the next window of. Hugin opens a mail from a
/// Heimdall card as a whole new Mail viewer, which would otherwise tile; asked first, it floats
/// in the middle of the screen like a reply.
struct FloatRequest {
    /// Posted on the distributed notification center with `bundleID` and `seconds`.
    static let notification = Notification.Name("com.paneless.floatNext")
    /// However long a request asks for, it never lasts longer than this.
    static let longest: TimeInterval = 5

    private var until: [String: Date] = [:]

    mutating func ask(_ bundleID: String, for seconds: TimeInterval, now: Date) {
        until[bundleID] = now.addingTimeInterval(min(max(seconds, 0), Self.longest))
    }

    /// Whether this new window is the one asked for. Only a standard window answers a request,
    /// and only once: popups and sheets the app opens on the way leave it standing.
    mutating func take(_ bundleID: String?, subrole: String?, now: Date) -> Bool {
        guard let bundleID, let end = until[bundleID], subrole == "AXStandardWindow" else { return false }
        until[bundleID] = nil
        return now < end
    }
}
