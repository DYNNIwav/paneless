import CoreGraphics

/// The tiled window focus goes back to when a floating window closes. A mail Hugin floats over
/// the workspace takes focus while it is open; closed, the keyboard returns to the tiled window
/// Pål was in, not to whatever window macOS picks.
struct FocusReturn {
    private var last: CGWindowID?

    mutating func focused(_ windowID: CGWindowID, tiled: Bool) {
        if tiled { last = windowID }
    }

    /// The tiled window last focused, while it is still tiled on this workspace.
    func heir(tiledHere: [CGWindowID]) -> CGWindowID? {
        guard let last, tiledHere.contains(last) else { return nil }
        return last
    }
}
