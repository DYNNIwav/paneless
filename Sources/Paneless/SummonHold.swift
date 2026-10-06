import Foundation

/// Apps another app has asked Paneless to leave where they are for a moment. Hugin brings
/// Messages forward for up to a second or so to mark a chat read, and focus-follows-app would
/// otherwise drag the Messages window off its workspace onto the current one.
struct SummonHold {
    /// Posted on the distributed notification center with `bundleID` and `seconds`.
    static let notification = Notification.Name("com.paneless.holdSummon")
    /// However long a hold asks for, it never lasts longer than this.
    static let longest: TimeInterval = 5

    private var until: [String: Date] = [:]

    mutating func hold(_ bundleID: String, for seconds: TimeInterval, now: Date) {
        until[bundleID] = now.addingTimeInterval(min(max(seconds, 0), Self.longest))
    }

    func isHeld(_ bundleID: String?, now: Date) -> Bool {
        guard let bundleID, let end = until[bundleID] else { return false }
        return now < end
    }
}
