import CoreGraphics

/// Close-focus policy, separated from AX so event ordering is deterministic in tests.
enum WindowFocus {
    enum Location { case floating, tiled, minimized, hidden, unmanaged }

    /// Only the observed AX element belonging to this tracked live window protects focus.
    static func liveFocus(window: CGWindowID, process: Int32, trackedProcess: Int32?,
                          sameElement: Bool, location: Location) -> CGWindowID? {
        guard process == trackedProcess, sameElement else { return nil }
        switch location {
        case .floating, .tiled: return window
        case .minimized, .hidden, .unmanaged: return nil
        }
    }

    /// The window a keyboard action acts on. The system's own answer wins whenever it names a
    /// window managed on this workspace: Paneless hears of a focus change inside an app, but
    /// not always of a click or Cmd+Tab over to another app, so what it remembers can be the
    /// window used before. Acting on that moved or closed a window other than the one in
    /// front. What is remembered still answers when the system names nothing managed here,
    /// and while it is fresh: for a moment after Paneless moves focus itself the system still
    /// names the window it moved from, and a second key pressed quickly must not act on that.
    static func actionTarget(live: CGWindowID?, remembered: CGWindowID?,
                             liveIsManagedHere: Bool, rememberedIsFresh: Bool) -> CGWindowID? {
        if rememberedIsFresh, let remembered { return remembered }
        if let live, liveIsManagedHere { return live }
        return remembered ?? live
    }

    /// How long what Paneless remembers is taken over the system's answer after it was set.
    static let freshFor: Double = 0.5

    static func afterClosingTiled(destroyed: CGWindowID, focused: CGWindowID?,
                                  appStillTiled: Bool, focusedSurvives: Bool) -> Bool {
        if focusedSurvives, let focused, focused != destroyed { return false }
        return focused == destroyed || focused == nil || !appStillTiled
    }

    static func afterClosingFloating(destroyed: CGWindowID, focused: CGWindowID?,
                                     focusedProcess: Int32?, destroyedProcess: Int32?,
                                     survivingFocus: CGWindowID?) -> Bool {
        if let survivingFocus, survivingFocus != destroyed { return false }
        return focused == destroyed || focused == nil || focusedProcess == destroyedProcess
    }
}
