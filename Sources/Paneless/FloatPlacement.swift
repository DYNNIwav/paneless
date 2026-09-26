import CoreGraphics

/// What Paneless does with a window the moment it first appears.
enum Placement: Equatable {
    /// Joins the layout.
    case tile
    /// Floats, and is moved once to the middle of the screen being worked on.
    case floatCentered
    /// Floats where the app put it. Paneless never moves it.
    case leaveAlone
}

/// What the accessibility API says about a new window, read once when it appears.
/// Any attribute can be missing: a slow app answers some reads and not others.
struct WindowTraits: Equatable {
    var role: String?
    var subrole: String?
    var identifier: String?
    var bundleID: String?
}

/// A display in accessibility coordinates: origin top left of the primary screen, y down.
struct ScreenRects: Equatable {
    let frame: CGRect
    let visible: CGRect
}

/// The pure decisions behind floating a new window in the middle of the screen.
/// Nothing in here reads the system, so every rule is pinned by a test.
enum FloatPlacement {
    /// Ghostty names its Quick Terminal panel so window managers can recognise it, and it
    /// drops from the top edge by design. Set in Ghostty's QuickTerminalWindow.swift and
    /// present verbatim in the shipped binary (Ghostty 1.3.1).
    static let ghosttyQuickTerminalID = "com.mitchellh.ghostty.quickTerminal"

    static let mailBundleID = "com.apple.mail"

    /// Mail tags its main viewer windows "Mail.messageViewer.window.1", ".2" and so on,
    /// in English whatever the system language (read on a Norwegian system, where the
    /// same window's title is "Alle innbokser"). Every other standard window Mail opens
    /// is a single message: a new message, a reply, a forward, or one opened on its own.
    static let mailViewerIDPrefix = "Mail.messageViewer."

    /// Window kinds that are real, movable windows. A missing subrole is let through: a
    /// failed read is not evidence of anything. AXUnknown is what borderless popups,
    /// suggestion lists and overlays report, and those are left where the app put them.
    private static let realWindowSubroles: Set<String> = [
        "AXStandardWindow", "AXDialog", "AXFloatingWindow",
        "AXSystemDialog", "AXSystemFloatingWindow",
    ]

    /// Mail compose windows are ordinary standard windows, told apart from the viewer
    /// only by the viewer's identifier. An unreadable identifier counts as a compose
    /// window, because the viewer's is always set by Mail itself.
    static func isMailCompose(_ t: WindowTraits) -> Bool {
        guard t.bundleID == mailBundleID, t.subrole == "AXStandardWindow" else { return false }
        return !(t.identifier ?? "").hasPrefix(mailViewerIDPrefix)
    }

    /// - Parameters:
    ///   - floatsByRule: Paneless's existing reasons to float it: a float_apps rule, a
    ///     dialog subrole, a small window or a secondary window.
    ///   - tiledBefore: it was in the layout before and is coming back, so it goes back.
    static func placement(for t: WindowTraits, floatsByRule: Bool, tiledBefore: Bool) -> Placement {
        // Menus, popovers and anything else that is not a window stay out of it entirely.
        if let role = t.role, role != "AXWindow" { return .leaveAlone }
        // A sheet belongs to its parent; the Quick Terminal to the top edge.
        if t.subrole == "AXSheet" || t.identifier == ghosttyQuickTerminalID { return .leaveAlone }
        // Coming back from Cmd+H or a minimise: back into the layout, or, if a rule
        // floats it, left wherever it is. It was centred the first time, not again.
        if tiledBefore { return floatsByRule ? .leaveAlone : .tile }

        let wantsFloat = floatsByRule || isMailCompose(t)
        guard wantsFloat else { return .tile }
        if let subrole = t.subrole, !realWindowSubroles.contains(subrole) { return .leaveAlone }
        return .floatCentered
    }

    /// The screen being worked on: the one holding the centre of the window that had
    /// focus, else the one under the mouse, else the first.
    static func workingScreen(focusedFrame: CGRect?, mouse: CGPoint, screens: [ScreenRects]) -> ScreenRects? {
        if let f = focusedFrame,
           let s = screens.first(where: { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) }) {
            return s
        }
        return screens.first { $0.frame.contains(mouse) } ?? screens.first
    }

    /// A frame of `size` in the exact centre of the screen, shrunk to fit its visible
    /// frame and then nudged inside it, so it never lands under the menu bar or Dock.
    static func centeredFrame(size: CGSize, on screen: ScreenRects) -> CGRect {
        let v = screen.visible
        let w = min(size.width, v.width)
        let h = min(size.height, v.height)
        var x = (screen.frame.midX - w / 2).rounded()
        var y = (screen.frame.midY - h / 2).rounded()
        x = min(max(x, v.minX), v.maxX - w)
        y = min(max(y, v.minY), v.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Converts an AppKit screen rect (origin bottom left, y up) to accessibility
    /// coordinates, measured against the primary screen's height.
    static func axRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
