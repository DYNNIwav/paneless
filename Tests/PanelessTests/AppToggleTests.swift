import Testing
@testable import Paneless

@Suite struct AppToggleTests {
    @Test func aBindingNamesTheAppItToggles() {
        guard case .toggleApp(let app)? = PanelessConfig.parseAction("toggle_app Visual Studio Code") else {
            Issue.record("toggle_app did not parse")
            return
        }
        #expect(app == "Visual Studio Code")
        #expect(PanelessConfig.actionString(.toggleApp("Terminal")) == "toggle_app Terminal")
        #expect(PanelessConfig.parseAction("toggle_app") == nil)
    }

    @Test func pressingHidesTheAppInFrontAndOpensItOtherwise() {
        #expect(AppToggle.step(isFrontmost: true) == .hide)
        #expect(AppToggle.step(isFrontmost: false) == .open)
    }

    @Test func anAppIsFoundByNameOrBundleID() {
        let terminal = AppToggle.applicationURL(for: "Terminal")
        #expect(terminal?.lastPathComponent == "Terminal.app")
        #expect(AppToggle.applicationURL(for: "com.apple.Terminal")?.lastPathComponent == "Terminal.app")
        #expect(AppToggle.applicationURL(for: "No Such App Here") == nil)
    }
}
