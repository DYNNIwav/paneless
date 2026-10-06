import AppKit
import Testing
@testable import Paneless

@MainActor @Suite struct UpdaterTests {
    @Test func manualChecksDoNotDuplicateACycle() {
        var checks = 0
        let updater = PanelessUpdater(check: { checks += 1 }, canCheck: { true })
        updater.request()
        updater.request()
        #expect(checks == 1)
        updater.ended(error: nil)
        updater.request()
        #expect(checks == 2)
    }

    @Test func aBusyControllerCannotStartAnotherCheck() {
        var checks = 0
        let updater = PanelessUpdater(check: { checks += 1 }, canCheck: { false })
        updater.request()
        #expect(checks == 0)
        #expect(!updater.validateMenuItem(updater.menuItem()))
    }

    @Test func aStagedUpdateOffersAnExplicitRestart() {
        var checks = 0
        var installs = 0
        let updater = PanelessUpdater(check: { checks += 1 }, canCheck: { false })
        updater.stage(version: "0.7.0", install: { installs += 1 })
        let menu = updater.menuItem()
        #expect(updater.validateMenuItem(menu))
        #expect(menu.title == "Restart to Update (0.7.0)")
        #expect(installs == 0)
        updater.request()
        #expect(installs == 1)
        #expect(checks == 0)
    }

    @Test func aFailedCycleDiscardsTheExpiredRestartCallback() {
        var checks = 0
        var installs = 0
        let updater = PanelessUpdater(check: { checks += 1 }, canCheck: { true })
        updater.stage(version: "0.7.0", install: { installs += 1 })
        updater.ended(error: NSError(domain: "test", code: 1))
        updater.request()
        #expect(installs == 0)
        #expect(checks == 1)
        let menu = updater.menuItem()
        #expect(!updater.validateMenuItem(menu))
        #expect(menu.title == "Check for Updates…")
    }

    @Test func aBuildWithoutAFeedLeavesUpdatesDisabled() {
        let updater = PanelessUpdater()
        updater.start(info: [:])
        #expect(!updater.validateMenuItem(updater.menuItem()))
    }

}
