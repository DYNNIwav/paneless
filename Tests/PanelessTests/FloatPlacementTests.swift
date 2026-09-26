import CoreGraphics
import Testing
@testable import Paneless

// Screens in accessibility coordinates (y down from the primary screen's top).
// Primary 1920x1080 with a 25pt menu bar and a 70pt Dock at the bottom.
private let primary = ScreenRects(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visible: CGRect(x: 0, y: 25, width: 1920, height: 985)
)
// A second screen to the LEFT and above: negative origin on both axes.
private let leftScreen = ScreenRects(
    frame: CGRect(x: -2560, y: -360, width: 2560, height: 1440),
    visible: CGRect(x: -2560, y: -335, width: 2560, height: 1415)
)

@Suite struct CenteredFrameTests {
    @Test func fitsExactlyInTheMiddleOfTheScreen() {
        let r = FloatPlacement.centeredFrame(size: CGSize(width: 800, height: 600), on: primary)
        #expect(r == CGRect(x: 560, y: 240, width: 800, height: 600))
    }

    @Test func keepsItsSizeWhenItFits() {
        let r = FloatPlacement.centeredFrame(size: CGSize(width: 420, height: 632), on: primary)
        #expect(r.size == CGSize(width: 420, height: 632))
    }

    @Test func tallWindowIsNudgedBelowTheMenuBarAndAboveTheDock() {
        // 970 tall: centred on the full screen its top would be at 55, bottom at 1025,
        // which is under the Dock (visible ends at 1010). Nudged up to end at 1010.
        let r = FloatPlacement.centeredFrame(size: CGSize(width: 600, height: 970), on: primary)
        #expect(r == CGRect(x: 660, y: 40, width: 600, height: 970))
        #expect(primary.visible.contains(r))
    }

    @Test func windowLargerThanTheScreenIsClampedToTheVisibleFrame() {
        let r = FloatPlacement.centeredFrame(size: CGSize(width: 3000, height: 2000), on: primary)
        #expect(r == primary.visible)
    }

    @Test func negativeOriginScreenCentresOnItself() {
        let r = FloatPlacement.centeredFrame(size: CGSize(width: 1000, height: 500), on: leftScreen)
        #expect(r == CGRect(x: -1780, y: 110, width: 1000, height: 500))
        #expect(leftScreen.visible.contains(r))
    }

    @Test func oddSizesLandOnWholePoints() {
        let r = FloatPlacement.centeredFrame(size: CGSize(width: 801, height: 601), on: primary)
        #expect(r.origin.x == r.origin.x.rounded() && r.origin.y == r.origin.y.rounded())
    }

    @Test func cocoaRectsConvertToAccessibilityCoordinates() {
        // AppKit: second screen above-left of a 1080-tall primary, origin bottom left.
        let cocoa = CGRect(x: -2560, y: -0, width: 2560, height: 1440)
        #expect(FloatPlacement.axRect(fromCocoa: cocoa, primaryHeight: 1080)
            == CGRect(x: -2560, y: -360, width: 2560, height: 1440))
        // Visible frame with a 70pt Dock at the bottom and a 25pt menu bar at the top.
        #expect(FloatPlacement.axRect(fromCocoa: CGRect(x: 0, y: 70, width: 1920, height: 985), primaryHeight: 1080)
            == primary.visible)
    }
}

@Suite struct WorkingScreenTests {
    let screens = [primary, leftScreen]

    @Test func followsTheWindowThatHadFocus() {
        let focused = CGRect(x: -2000, y: 0, width: 800, height: 600)
        let s = FloatPlacement.workingScreen(focusedFrame: focused, mouse: CGPoint(x: 100, y: 100), screens: screens)
        #expect(s == leftScreen)
    }

    @Test func fallsBackToTheMouseWithoutAFocusedWindow() {
        let s = FloatPlacement.workingScreen(focusedFrame: nil, mouse: CGPoint(x: -10, y: -10), screens: screens)
        #expect(s == leftScreen)
    }

    @Test func fallsBackToTheMouseWhenTheFocusedWindowIsOffEveryScreen() {
        // A window parked off-screen on another workspace says nothing about where Pål is.
        let parked = CGRect(x: 9000, y: 9000, width: 800, height: 600)
        let s = FloatPlacement.workingScreen(focusedFrame: parked, mouse: CGPoint(x: 500, y: 500), screens: screens)
        #expect(s == primary)
    }

    @Test func fallsBackToTheFirstScreenWhenNothingMatches() {
        let s = FloatPlacement.workingScreen(focusedFrame: nil, mouse: CGPoint(x: 99999, y: 0), screens: screens)
        #expect(s == primary)
        #expect(FloatPlacement.workingScreen(focusedFrame: nil, mouse: .zero, screens: []) == nil)
    }
}

@Suite struct PlacementTests {
    func place(_ t: WindowTraits, rule: Bool = false, tiledBefore: Bool = false) -> Placement {
        FloatPlacement.placement(for: t, floatsByRule: rule, tiledBefore: tiledBefore)
    }

    let standard = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow", identifier: nil, bundleID: "com.example")

    @Test func ordinaryWindowTiles() {
        #expect(place(standard) == .tile)
    }

    @Test func windowFloatedByARuleIsCentred() {
        #expect(place(standard, rule: true) == .floatCentered)
        let dialog = WindowTraits(role: "AXWindow", subrole: "AXDialog", identifier: nil, bundleID: "com.example")
        #expect(place(dialog, rule: true) == .floatCentered)
    }

    @Test func sheetIsLeftAttachedToItsParent() {
        let sheet = WindowTraits(role: "AXWindow", subrole: "AXSheet", identifier: nil, bundleID: "com.example")
        #expect(place(sheet, rule: true) == .leaveAlone)
    }

    @Test func ghosttyQuickTerminalIsLeftAtTheTopEdge() {
        let qt = WindowTraits(role: "AXWindow", subrole: "AXFloatingWindow",
                              identifier: "com.mitchellh.ghostty.quickTerminal", bundleID: "com.mitchellh.ghostty")
        #expect(place(qt, rule: true) == .leaveAlone)
        #expect(place(qt) == .leaveAlone)
    }

    @Test func ghosttyTerminalWindowStillTiles() {
        // Verified read-only: a normal Ghostty window reports this identifier.
        let term = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow",
                                identifier: "TerminalWindowRestoration", bundleID: "com.mitchellh.ghostty")
        #expect(place(term) == .tile)
    }

    @Test func menusPopoversAndOtherNonWindowsAreLeftAlone() {
        for role in ["AXMenu", "AXPopover", "AXGroup"] {
            #expect(place(WindowTraits(role: role, subrole: nil, identifier: nil, bundleID: nil), rule: true) == .leaveAlone)
            #expect(place(WindowTraits(role: role, subrole: nil, identifier: nil, bundleID: nil)) == .leaveAlone)
        }
    }

    @Test func borderlessPopupThatWouldFloatIsNotMoved() {
        let popup = WindowTraits(role: "AXWindow", subrole: "AXUnknown", identifier: nil, bundleID: "com.example")
        #expect(place(popup, rule: true) == .leaveAlone)
        #expect(place(popup) == .tile, "only the float decision is gated, tiling is unchanged")
    }

    @Test func unreadableAttributesChangeNothing() {
        let blank = WindowTraits(role: nil, subrole: nil, identifier: nil, bundleID: "com.example")
        #expect(place(blank) == .tile)
        #expect(place(blank, rule: true) == .floatCentered)
    }

    @Test func mailViewerTilesAndComposeFloats() {
        // Verified read-only on Pål's Norwegian system: title "Alle innbokser – ...",
        // identifier "Mail.messageViewer.window.1".
        let viewer = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow",
                                  identifier: "Mail.messageViewer.window.1", bundleID: "com.apple.mail")
        #expect(place(viewer) == .tile)
        #expect(place(WindowTraits(role: "AXWindow", subrole: "AXStandardWindow",
                                   identifier: "Mail.messageViewer.window.2", bundleID: "com.apple.mail")) == .tile)

        let compose = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow",
                                   identifier: nil, bundleID: "com.apple.mail")
        #expect(place(compose) == .floatCentered)
        var named = compose
        named.identifier = "ComposeWindow"
        #expect(place(named) == .floatCentered)
    }

    @Test func sameIdentifierFromAnotherAppIsNotMailCompose() {
        let other = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow", identifier: nil, bundleID: "com.example.mail")
        #expect(place(other) == .tile)
    }

    @Test func returningWindowGoesBackWithoutBeingCentredAgain() {
        #expect(place(standard, tiledBefore: true) == .tile)
        #expect(place(standard, rule: true, tiledBefore: true) == .leaveAlone)
        let compose = WindowTraits(role: "AXWindow", subrole: "AXStandardWindow", identifier: nil, bundleID: "com.apple.mail")
        #expect(place(compose, tiledBefore: true) == .tile)
    }
}
