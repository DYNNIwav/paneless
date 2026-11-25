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

    @Test func closingACheckerDoesNotBuryTheSameProcessUpdateWindow() {
        #expect(!WindowFocus.afterClosingFloating(destroyed: 10, focused: 11,
            focusedProcess: 100, destroyedProcess: 100, survivingFocus: 11))
    }

    @Test func aLateCloseCannotUndoAnObservedBrowserSwitch() {
        // The cached focus still names the closing window, but AX already sees the browser.
        #expect(!WindowFocus.afterClosingFloating(destroyed: 10, focused: 10,
            focusedProcess: 100, destroyedProcess: 100, survivingFocus: 20))
    }

    @Test func aClosedOrUnknownFloatingFocusStillReturnsToTheTile() {
        #expect(WindowFocus.afterClosingFloating(destroyed: 10, focused: 10,
            focusedProcess: 100, destroyedProcess: 100, survivingFocus: nil))
        #expect(WindowFocus.afterClosingFloating(destroyed: 10, focused: nil,
            focusedProcess: nil, destroyedProcess: 100, survivingFocus: nil))
    }

    /// Clicked or Cmd+Tabbed over to another app: Paneless still remembers the window used
    /// before, and Option+Shift+number must take the one in front.
    @Test func anActionTakesTheWindowInFrontNotTheOneRememberedFromBefore() {
        #expect(WindowFocus.actionTarget(live: 20, remembered: 10,
            liveIsManagedHere: true, rememberedIsFresh: false) == 20)
        #expect(WindowFocus.actionTarget(live: 20, remembered: nil,
            liveIsManagedHere: true, rememberedIsFresh: false) == 20)
    }

    /// A menu, a popup or an app Paneless leaves alone is in front: the remembered window stands.
    @Test func whatIsRememberedAnswersWhenTheSystemNamesNothingManagedHere() {
        #expect(WindowFocus.actionTarget(live: 99, remembered: 10,
            liveIsManagedHere: false, rememberedIsFresh: false) == 10)
        #expect(WindowFocus.actionTarget(live: nil, remembered: 10,
            liveIsManagedHere: false, rememberedIsFresh: false) == 10)
        #expect(WindowFocus.actionTarget(live: 99, remembered: nil,
            liveIsManagedHere: false, rememberedIsFresh: false) == 99)
    }

    /// Paneless just moved focus itself and the system has not caught up: a second key
    /// pressed quickly acts on the window Paneless moved to.
    @Test func aFocusPanelessJustSetIsNotOverruledByTheSystemsLag() {
        #expect(WindowFocus.actionTarget(live: 10, remembered: 20,
            liveIsManagedHere: true, rememberedIsFresh: true) == 20)
    }

    /// A shortcut held a moment too long: what acts once on the focused window does not run
    /// again on the window that took its place, while stepping and resizing still repeat.
    @Test func aHeldKeyRepeatsOnlyWhatIsMeantToRepeat() {
        let once: [WMAction] = [.moveToWorkspace(3), .closeFocused, .toggleFloat, .toggleFullscreen,
                                .minimizeToWorkspace, .toggleApp("Terminal"), .swapWithMaster, .cycleLayout,
                                .setMark("a"), .moveToMonitor(.left), .switchWorkspace(2)]
        for action in once { #expect(!action.repeatsWhileHeld) }
        let held: [WMAction] = [.focusNext, .focusPrev, .focusDirection(.left), .growFocused, .shrinkFocused,
                                .increaseGap, .niriMoveLeft, .niriMoveColumnRight]
        for action in held { #expect(action.repeatsWhileHeld) }
    }
}
