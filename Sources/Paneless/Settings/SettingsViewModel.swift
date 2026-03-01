import Cocoa
import Combine
import SwiftUI

class SettingsViewModel: ObservableObject {

    // MARK: - Layout

    @Published var tilingMode: String = "hyprland"
    @Published var innerGap: CGFloat = 8
    @Published var outerGap: CGFloat = 8
    @Published var singleWindowPadding: CGFloat = 0
    @Published var animations: Bool = true
    @Published var nativeAnimation: Bool = false
    @Published var focusFollowsMouse: Bool = false
    @Published var focusFollowsApp: Bool = true
    @Published var autoFloatDialogs: Bool = true
    @Published var forceProMotion: Bool = false
    @Published var dimUnfocused: CGFloat = 0
    @Published var hyperkeyOption: String = "disabled"
    @Published var niriColumnWidth: CGFloat = 1.0

    // MARK: - Border

    @Published var borderEnabled: Bool = false
    @Published var borderWidth: CGFloat = 2
    @Published var borderActiveColor: Color = Color(red: 0.4, green: 0.8, blue: 1.0)
    @Published var borderInactiveColor: Color = Color(red: 0.27, green: 0.27, blue: 0.27)
    @Published var borderRadius: CGFloat = 10

    // MARK: - Rules

    @Published var floatApps: [String] = []
    @Published var excludeApps: [String] = []
    @Published var stickyApps: [String] = []
    @Published var swallowApps: [String] = []
    @Published var appLayoutRules: [String: String] = [:]

    // MARK: - Workspaces

    @Published var workspaceNames: [Int: String] = [:]
    @Published var appWorkspaceRules: [String: Int] = [:]

    // MARK: - Menu Bar

    @Published var menubarActiveColor: Color? = nil
    @Published var menubarInactiveColor: Color? = nil
    @Published var useCustomMenubarActive: Bool = false
    @Published var useCustomMenubarInactive: Bool = false

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var isReloading = false
    private var saveWorkItem: DispatchWorkItem?

    // Known hyperkey options
    static let hyperkeyOptions = ["disabled", "caps_lock", "f18", "grave"]

    init() {
        loadFromConfig()

        // Debounced auto-save: any @Published change triggers save after 0.3s
        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, !self.isReloading else { return }
                self.saveToConfig()
            }
            .store(in: &cancellables)
    }

    // MARK: - Load

    func loadFromConfig() {
        isReloading = true

        let config = PanelessConfig.load()

        tilingMode = config.tilingMode
        innerGap = config.innerGap
        outerGap = config.outerGap
        singleWindowPadding = config.singleWindowPadding
        animations = config.animations
        nativeAnimation = config.nativeAnimation
        focusFollowsMouse = config.focusFollowsMouse
        focusFollowsApp = config.focusFollowsApp
        autoFloatDialogs = config.autoFloatDialogs
        forceProMotion = config.forceProMotion
        dimUnfocused = config.dimUnfocused
        niriColumnWidth = config.niriColumnWidth

        if let code = config.hyperkeyCode, let name = KeyNames.keyName(for: code) {
            hyperkeyOption = name
        } else {
            hyperkeyOption = "disabled"
        }

        // Filter out bundle IDs for display, keep only human-readable names
        floatApps = config.floatApps.filter { !$0.contains(".") }.sorted()
        excludeApps = config.excludeApps.filter { !$0.contains(".") }.sorted()
        stickyApps = config.stickyApps.filter { !$0.contains(".") }.sorted()
        swallowApps = config.swallowApps.filter { !$0.contains(".") }.sorted()
        appLayoutRules = config.appLayoutRules
        workspaceNames = config.workspaceNames
        appWorkspaceRules = config.appWorkspaceRules

        borderEnabled = config.border.enabled
        borderWidth = config.border.width
        borderActiveColor = Color(config.border.activeColor)
        borderInactiveColor = Color(config.border.inactiveColor)
        borderRadius = config.border.radius

        if let c = config.menubarActiveColor {
            menubarActiveColor = Color(c)
            useCustomMenubarActive = true
        } else {
            menubarActiveColor = Color.blue
            useCustomMenubarActive = false
        }

        if let c = config.menubarInactiveColor {
            menubarInactiveColor = Color(c)
            useCustomMenubarInactive = true
        } else {
            menubarInactiveColor = Color.gray
            useCustomMenubarInactive = false
        }

        // Keep isReloading true past the debounce window (300ms) so the
        // debounced save sink doesn't fire from these property changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isReloading = false
        }
    }

    // MARK: - Save

    func saveToConfig() {
        var config = PanelessConfig.load()

        config.tilingMode = tilingMode
        config.innerGap = innerGap
        config.outerGap = outerGap
        config.singleWindowPadding = singleWindowPadding
        config.animations = animations
        config.nativeAnimation = nativeAnimation
        config.focusFollowsMouse = focusFollowsMouse
        config.focusFollowsApp = focusFollowsApp
        config.autoFloatDialogs = autoFloatDialogs
        config.forceProMotion = forceProMotion
        config.dimUnfocused = dimUnfocused
        config.niriColumnWidth = niriColumnWidth

        if hyperkeyOption == "disabled" {
            config.hyperkeyCode = nil
        } else {
            config.hyperkeyCode = KeyNames.keyCode(for: hyperkeyOption)
        }

        config.floatApps = Set(floatApps)
        config.excludeApps = Set(excludeApps)
        config.stickyApps = Set(stickyApps)
        config.swallowApps = Set(swallowApps)
        config.appLayoutRules = appLayoutRules
        config.workspaceNames = workspaceNames
        config.appWorkspaceRules = appWorkspaceRules

        config.border.enabled = borderEnabled
        config.border.width = borderWidth
        config.border.activeColor = NSColor(borderActiveColor)
        config.border.inactiveColor = NSColor(borderInactiveColor)
        config.border.radius = borderRadius

        if useCustomMenubarActive, let c = menubarActiveColor {
            config.menubarActiveColor = NSColor(c)
        } else {
            config.menubarActiveColor = nil
        }

        if useCustomMenubarInactive, let c = menubarInactiveColor {
            config.menubarInactiveColor = NSColor(c)
        } else {
            config.menubarInactiveColor = nil
        }

        // Tell WindowManager to skip the file-watcher reload (we apply live below)
        WindowManager.shared.suppressNextReload = true
        config.save()

        // Apply config changes live without going through the file-watcher path
        applyConfigLive(config)
    }

    private func applyConfigLive(_ config: PanelessConfig) {
        let wm = WindowManager.shared
        let oldConfig = wm.config

        wm.config = config
        wm.layoutEngine.config = config
        BorderManager.shared.config = config.border
        wm.eventTap.keyBindings = config.keyBindings
        wm.eventTap.hyperkeyCode = config.hyperkeyCode
        Animator.shared.enabled = config.animations

        // Refresh borders: remove if disabled, reposition if enabled
        if !config.border.enabled {
            BorderManager.shared.removeAll()
        } else if let focusedID = wm.focusedWindowID,
                  let tracked = wm.trackedWindows[focusedID] {
            BorderManager.shared.updateFocus(windowID: focusedID, frame: tracked.frame)
        }

        // Only retile when layout-affecting settings changed
        let needsRetile = oldConfig.innerGap != config.innerGap
            || oldConfig.outerGap != config.outerGap
            || oldConfig.singleWindowPadding != config.singleWindowPadding
            || oldConfig.tilingMode != config.tilingMode
            || oldConfig.niriColumnWidth != config.niriColumnWidth

        if needsRetile {
            wm.retile()
        }
    }
}
