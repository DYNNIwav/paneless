import CoreGraphics
import Testing
@testable import Paneless

private let tile = CGRect(x: 1924, y: 42, width: 1904, height: 1566)

@Suite struct ScaleInTests {
    @Test func aGenuinelyNewWindowKeepsThePopin() {
        let appPlaced = CGRect(x: 300, y: 200, width: 800, height: 600)
        #expect(ScaleIn.settledStart(target: tile, actual: appPlaced, tiledBefore: false) == nil)
        #expect(ScaleIn.settledStart(target: tile, actual: nil, tiledBefore: false) == nil)
    }

    @Test func aWindowBackFromHideGlidesFromWhereItIs() {
        let elsewhere = CGRect(x: 1000, y: 100, width: 900, height: 700)
        #expect(ScaleIn.settledStart(target: tile, actual: elsewhere, tiledBefore: true) == elsewhere)
    }

    @Test func aWindowBackFromHideWithNoReadableFrameStartsOnItsTile() {
        #expect(ScaleIn.settledStart(target: tile, actual: nil, tiledBefore: true) == tile)
    }

    @Test func aNewWindowAlreadyOnItsTileStaysPut() {
        let nearlyThere = tile.offsetBy(dx: 0.5, dy: -0.5)
        #expect(ScaleIn.settledStart(target: tile, actual: nearlyThere, tiledBefore: false) == nearlyThere)
    }

    @Test func thePopinStartsAtFourFifthsAroundTheTileCentre() {
        let r = ScaleIn.popin(tile)
        #expect(r.width == tile.width * 0.8 && r.height == tile.height * 0.8)
        #expect(r.midX == tile.midX && r.midY == tile.midY)
    }
}
