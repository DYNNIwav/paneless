import Testing
@testable import Paneless

@Suite struct WindowFocusTests {
    @Test func closingMailViewerDoesNotBuryItsFocusedFloatingReply() {
        #expect(!WindowFocus.afterClosingTiled(destroyed: 10, focused: 11,
            appStillTiled: false, focusedSurvives: true))
    }

    @Test func closingAnUnfocusedViewerDoesNotUndoADeliberateBrowserSwitch() {
        #expect(!WindowFocus.afterClosingTiled(destroyed: 10, focused: 20,
            appStillTiled: false, focusedSurvives: true))
    }

    @Test func closingTheFocusedWindowStillChoosesAnHeir() {
        #expect(WindowFocus.afterClosingTiled(destroyed: 10, focused: 10,
            appStillTiled: false, focusedSurvives: false))
        #expect(WindowFocus.afterClosingTiled(destroyed: 10, focused: 10,
            appStillTiled: true, focusedSurvives: false))
    }

    @Test func unknownFocusStillAllowsRecovery() {
        #expect(WindowFocus.afterClosingTiled(destroyed: 10, focused: nil,
            appStillTiled: false, focusedSurvives: false))
    }

    @Test func aFocusOnAnotherWorkspaceDoesNotPreventTheOldFallback() {
        #expect(WindowFocus.afterClosingTiled(destroyed: 10, focused: 30,
            appStillTiled: false, focusedSurvives: false))
    }

    @Test func onlyTheExactObservedLiveWindowProtectsFocus() {
        for location in [WindowFocus.Location.floating, .tiled] {
            #expect(WindowFocus.liveFocus(window: 11, process: 100,
                trackedProcess: 100, sameElement: true, location: location) == 11)
        }
        #expect(WindowFocus.liveFocus(window: 11, process: 101,
            trackedProcess: 100, sameElement: true, location: .floating) == nil)
        #expect(WindowFocus.liveFocus(window: 11, process: 100,
            trackedProcess: nil, sameElement: true, location: .floating) == nil)
        #expect(WindowFocus.liveFocus(window: 11, process: 100,
            trackedProcess: 100, sameElement: false, location: .floating) == nil)
        for location in [WindowFocus.Location.minimized, .hidden, .unmanaged] {
            #expect(WindowFocus.liveFocus(window: 11, process: 100,
                trackedProcess: 100, sameElement: true, location: location) == nil)
        }
    }
}
