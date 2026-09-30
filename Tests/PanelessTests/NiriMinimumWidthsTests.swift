import CoreGraphics
import Testing
@testable import Paneless

@Suite struct NiriMinimumWidthsTests {
    private let half = CGRect(x: 8, y: 25, width: 1896, height: 1000)

    @Test func oldFullWidthIsNotAMinimumAfterSuccessfulShrink() {
        var policy = NiriMinimumWidths()
        var frame = CGRect(x: 0, y: 25, width: 3816, height: 1000)
        let changed = policy.observe(1, target: half, settled: true, read: { frame }, resize: {
            frame = $0
            return true
        })
        #expect(!changed)
        #expect(policy.widths.isEmpty)
        #expect(frame == half)
    }

    @Test func refusedAndUnsettledWritesCannotBecomeFloors() {
        for settled in [true, false] {
            var policy = NiriMinimumWidths()
            for _ in 0..<8 {
                _ = policy.observe(1, target: half, settled: settled,
                    read: { CGRect(x: 0, y: 25, width: 3816, height: 1000) }, resize: { _ in false })
            }
            #expect(policy.widths.isEmpty)
        }
    }

    @Test func genuineMinimumRequiresTwoStableSuccessfulReadbacks() {
        var policy = NiriMinimumWidths()
        let actual = CGRect(x: 8, y: 25, width: 2100, height: 1000)
        let first = policy.observe(1, target: half, settled: true, read: { actual }, resize: { _ in true })
        #expect(!first)
        #expect(policy.widths.isEmpty)
        let second = policy.observe(1, target: half, settled: true, read: { actual }, resize: { _ in true })
        #expect(second)
        #expect(policy.widths[1] == 2100)
    }

    @Test func genuineWidthMinimumAlsoAllowsClampedHeight() {
        var policy = NiriMinimumWidths()
        let target = CGRect(x: 8, y: 25, width: 1896, height: 500)
        let actual = CGRect(x: 8, y: 25, width: 2100, height: 720)
        for _ in 0..<2 {
            _ = policy.observe(1, target: target, settled: true, read: { actual }, resize: { _ in true })
        }
        #expect(policy.widths[1] == 2100)
    }

    @Test func changingPostWriteFramesNeverEstablishMinimumAndRetriesAreBounded() {
        var policy = NiriMinimumWidths()
        var width: CGFloat = 3816
        var writes = 0
        for _ in 0..<10 {
            _ = policy.observe(1, target: half, settled: true,
                read: { CGRect(x: 0, y: 25, width: width, height: 1000) }, resize: { _ in
                    writes += 1
                    width -= 20
                    return true
                })
        }
        #expect(policy.widths.isEmpty)
        #expect(writes == 3)
    }

    @Test func newLayoutRevalidatesButUnchangedLayoutDoesNotJitter() {
        var policy = NiriMinimumWidths()
        _ = policy.prepare(monitor: "left", targets: [1: half.size])
        policy.widths[1] = 3816
        let unchanged = policy.prepare(monitor: "left", targets: [1: half.size])
        #expect(!unchanged)
        #expect(policy.widths[1] == 3816)
        let changed = policy.prepare(monitor: "left", targets: [1: half.size, 2: half.size])
        #expect(changed)
        #expect(policy.widths.isEmpty)
        policy.widths[1] = 2100
        _ = policy.prepare(monitor: "right", targets: [3: half.size])
        #expect(policy.widths[1] == 2100)
    }

    private func layout(_ count: Int, minima: [CGWindowID: CGFloat]) -> [NativeTiling.NiriColumnResult] {
        var offset: CGFloat = 0
        return NativeTiling.calculateNiriFrames(
            columns: (1...count).map { NiriColumn(windows: [CGWindowID($0)]) },
            region: TilingRegion(x: 0, y: 25, width: 3808, height: 1008), gap: 8,
            activeColumn: 0, defaultColumnWidth: 0.333, minColumnWidth: 500,
            fillScreen: true, minWidthByWindow: minima, resultingScrollOffset: &offset)
    }

    @Test(arguments: [2, 3]) func formerFullScreenAppSharesHalvesOrThirds(_ count: Int) {
        var policy = NiriMinimumWidths()
        let baseline = layout(count, minima: [:])
        for column in baseline {
            let (id, target) = column.windowFrames[0]
            var actual = CGRect(x: 0, y: 25, width: id == 1 ? 3816 : 658, height: 1000)
            _ = policy.observe(id, target: target, settled: true, read: { actual }, resize: {
                actual = $0
                return true
            })
        }
        let final = layout(count, minima: policy.widths)
        #expect(final.allSatisfy { $0.isVisible })
        #expect(final.allSatisfy { abs($0.windowFrames[0].frame.width - (3808 / CGFloat(count) - 8)) < 1 })
        #expect(policy.widths.isEmpty)
    }

    @Test func realAppMinimumIsHonouredWithoutUnboundedJitter() {
        var policy = NiriMinimumWidths()
        let target = layout(2, minima: [:])[0].windowFrames[0].frame
        let actual = CGRect(x: target.minX, y: target.minY, width: 2100, height: target.height)
        for _ in 0..<2 {
            _ = policy.observe(1, target: target, settled: true, read: { actual }, resize: { _ in true })
        }
        let final = layout(2, minima: policy.widths)
        #expect(final[0].windowFrames[0].frame.width == 2100)
        #expect(final.allSatisfy { $0.isVisible })
        var writes = 0
        for _ in 0..<10 {
            _ = policy.observe(1, target: final[0].windowFrames[0].frame, settled: true,
                read: { actual }, resize: { _ in writes += 1; return true })
        }
        #expect(writes == 0)
    }

    @Test func animationBreaksConsecutiveEvidenceAndManualShrinkDisprovesFloor() {
        var policy = NiriMinimumWidths()
        let actual = CGRect(x: 8, y: 25, width: 2100, height: 1000)
        _ = policy.observe(1, target: half, settled: true, read: { actual }, resize: { _ in true })
        policy.suspend()
        _ = policy.observe(1, target: half, settled: true, read: { actual }, resize: { _ in true })
        #expect(policy.widths.isEmpty)
        _ = policy.observe(1, target: half, settled: true, read: { actual }, resize: { _ in true })
        let accepted = policy.observe(1, target: actual, settled: true, read: { half }, resize: { _ in false })
        #expect(accepted)
        #expect(policy.widths.isEmpty)
    }
}
