import AppKit
import Sparkle

/// Sparkle owns downloads and installation. Only a menu click requests an immediate restart.
@MainActor final class PanelessUpdater: NSObject {
    private var controller: SPUStandardUpdaterController?
    private var check: () -> Void
    private var canCheck: () -> Bool
    private var checking = false
    private var stagedVersion: String?
    private var install: (() -> Void)?

    init(check: @escaping () -> Void = {}, canCheck: @escaping () -> Bool = { false }) {
        self.check = check
        self.canCheck = canCheck
        super.init()
    }

    func start(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard controller == nil,
              let feed = info["SUFeedURL"] as? String, URL(string: feed)?.scheme == "https",
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        check = { [weak controller] in controller?.checkForUpdates(nil) }
        canCheck = { [weak controller] in controller?.updater.canCheckForUpdates ?? false }
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(menuAction), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuAction() { request() }

    func request() {
        if let install { install(); return }
        guard !checking, canCheck() else { return }
        checking = true
        check()
    }

    func stage(version: String, install: @escaping () -> Void) {
        checking = false
        stagedVersion = version
        self.install = install
    }

    func ended(error: Error?) {
        checking = false
        stagedVersion = nil
        install = nil
        if let error = error as NSError?,
           !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) {
            panelessLog("Update failed: \(error.localizedDescription)")
        }
    }
}

extension PanelessUpdater: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(menuAction) else { return true }
        if let stagedVersion {
            item.title = "Restart to Update (\(stagedVersion))"
            return true
        }
        item.title = "Check for Updates…"
        return !checking && canCheck()
    }
}

extension PanelessUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        stage(version: item.displayVersionString, install: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { ended(error: error) }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        ended(error: error)
    }
}

extension PanelessUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}
