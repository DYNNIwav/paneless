import CoreGraphics
import Testing
@testable import Paneless

@Suite struct NiriMinWidthTests {
    @Test func aWindowStillCatchingUpWithAResizeIsNotLearned() {
        // Claude reads 2927 wide in a 1904 column for one poll while it shrinks.
        #expect(NiriMinWidth.learned(actual: 2927, previous: 3816, allocated: 1904, recorded: nil) == nil)
        #expect(NiriMinWidth.learned(actual: 2927, previous: nil, allocated: 1904, recorded: nil) == nil)
    }

    @Test func aWindowThatStaysWiderThanItsColumnIsLearned() {
        #expect(NiriMinWidth.learned(actual: 1100, previous: 1100, allocated: 900, recorded: nil) == 1100)
        #expect(NiriMinWidth.learned(actual: 1100, previous: 1102, allocated: 900, recorded: nil) == 1100)
    }

    @Test func aWindowThatFitsItsColumnIsNotLearned() {
        #expect(NiriMinWidth.learned(actual: 1904, previous: 1904, allocated: 1904, recorded: nil) == nil)
    }

    @Test func aWidthAlreadyRecordedIsNotLearnedAgain() {
        #expect(NiriMinWidth.learned(actual: 1100, previous: 1100, allocated: 900, recorded: 1100) == nil)
    }
}
