import CoreGraphics
import Testing
@testable import Paneless

@Suite struct ColumnWidthTests {
    @Test func aThirdStaysAThird() {
        #expect(ColumnWidth.choice(for: 0.333) == .third)
        #expect(ColumnWidth.choice(for: 1.0 / 3.0) == .third)
        #expect(ColumnWidth.choice(for: 0.5) == .half)
        #expect(ColumnWidth.choice(for: 0.667) == .twoThirds)
        #expect(ColumnWidth.choice(for: 1) == .full)
    }

    @Test func aWidthSetByHandIsKeptAndShown() {
        #expect(ColumnWidth.choice(for: 0.45) == .custom)
        #expect(ColumnWidth.custom.fraction == nil)
        #expect(ColumnWidth.choices(for: 0.45).contains(.custom))
        #expect(!ColumnWidth.choices(for: 0.5).contains(.custom))
    }
}
