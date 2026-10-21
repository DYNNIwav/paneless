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
