import CoreGraphics
import Testing
@testable import Paneless

/// Pål, 11 Oct: closing the mail Hugin floats with Cmd+W left focus nowhere useful. It goes back
/// to the tiled window he last used on that workspace, so the keyboard carries on where it was.
@Suite struct FocusReturnTests {
    @Test func aClosedFloatHandsFocusBackToTheLastTiledWindow() {
        var back = FocusReturn()
        back.focused(11, tiled: true)
        back.focused(12, tiled: true)
        back.focused(99, tiled: false)
        #expect(back.heir(tiledHere: [11, 12]) == 12)
    }

    /// The window last used closed too, or it lives on another workspace: nothing to go back to.
    @Test func aWindowNoLongerTiledHereIsNotFocused() {
        var back = FocusReturn()
        back.focused(12, tiled: true)
        #expect(back.heir(tiledHere: [11]) == nil)
        #expect(FocusReturn().heir(tiledHere: [11]) == nil)
    }
}
