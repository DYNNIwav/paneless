import CoreGraphics

/// Decides when a window has shown it cannot shrink to its niri column.
enum NiriMinWidth {
    static let tolerance: CGFloat = 4

    /// The width to learn as a window's minimum from one poll, or nil.
    /// A window still catching up with a resize reads wide for a poll and then
    /// settles, so only a width that holds across two polls counts.
    static func learned(actual: CGFloat, previous: CGFloat?, allocated: CGFloat, recorded: CGFloat?) -> CGFloat? {
        guard let previous, abs(previous - actual) <= tolerance,
              actual > allocated + tolerance,
              (recorded ?? 0) < actual - tolerance else { return nil }
        return actual
    }
}
