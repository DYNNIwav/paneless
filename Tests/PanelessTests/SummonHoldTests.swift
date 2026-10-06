import Foundation
import Testing
@testable import Paneless

@Suite struct SummonHoldTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func aHeldAppIsLeftAloneUntilTheHoldRunsOut() {
        var hold = SummonHold()
        hold.hold("com.apple.MobileSMS", for: 2, now: now)
        #expect(hold.isHeld("com.apple.MobileSMS", now: now.addingTimeInterval(1.9)))
        #expect(!hold.isHeld("com.apple.MobileSMS", now: now.addingTimeInterval(2)))
        #expect(!hold.isHeld("com.apple.Safari", now: now))
        #expect(!hold.isHeld(nil, now: now))
    }

    @Test func aHoldNeverOutlastsTheLongestAllowed() {
        var hold = SummonHold()
        hold.hold("com.apple.MobileSMS", for: 3_600, now: now)
        #expect(!hold.isHeld("com.apple.MobileSMS", now: now.addingTimeInterval(SummonHold.longest)))
    }
}
