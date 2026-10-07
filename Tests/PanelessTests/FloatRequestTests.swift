import Foundation
import Testing
@testable import Paneless

@Suite struct FloatRequestTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func theNextStandardWindowFloatsOnce() {
        var request = FloatRequest()
        request.ask("com.apple.mail", for: 3, now: now)
        let otherApp = request.take("com.apple.Safari", subrole: "AXStandardWindow", now: now)
        let popup = request.take("com.apple.mail", subrole: "AXUnknown", now: now)
        let mail = request.take("com.apple.mail", subrole: "AXStandardWindow", now: now.addingTimeInterval(0.3))
        let again = request.take("com.apple.mail", subrole: "AXStandardWindow", now: now.addingTimeInterval(0.4))
        #expect(!otherApp && !popup && mail && !again)
    }

    @Test func aRequestRunsOut() {
        var request = FloatRequest()
        request.ask("com.apple.mail", for: 3, now: now)
        let late = request.take("com.apple.mail", subrole: "AXStandardWindow", now: now.addingTimeInterval(3))
        request.ask("com.apple.mail", for: 3_600, now: now)
        let capped = request.take("com.apple.mail", subrole: "AXStandardWindow", now: now.addingTimeInterval(FloatRequest.longest))
        let unnamed = request.take(nil, subrole: "AXStandardWindow", now: now)
        #expect(!late && !capped && !unnamed)
    }
}
