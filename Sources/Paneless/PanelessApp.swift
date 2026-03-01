import Cocoa

// MARK: - Catppuccin Menu Bar Theme

private struct MenuBarTheme {
    var layoutColor: NSColor
    var activeWorkspaceColor: NSColor
    var inactiveWorkspaceColor: NSColor
    var titleColor: NSColor

    // Catppuccin Mocha (dark mode)
    static let mocha = MenuBarTheme(
        layoutColor:            NSColor.fromHex("#cba6f7")!,  // Mauve
        activeWorkspaceColor:   NSColor.fromHex("#89b4fa")!,  // Blue
        inactiveWorkspaceColor: NSColor.fromHex("#7f849c")!,  // Overlay1
        titleColor:             NSColor.fromHex("#a6adc8")!   // Subtext0
    )

    // Catppuccin Latte (light mode)
    static let latte = MenuBarTheme(
        layoutColor:            NSColor.fromHex("#8839ef")!,  // Mauve
        activeWorkspaceColor:   NSColor.fromHex("#1e66f5")!,  // Blue
        inactiveWorkspaceColor: NSColor.fromHex("#8c8fa1")!,  // Overlay1
        titleColor:             NSColor.fromHex("#6c6f85")!   // Subtext0
    )

    static var current: MenuBarTheme {
        let appearance = NSAppearance.currentDrawing()
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .mocha : .latte
    }
}

class PanelessAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var configWatcherSource: DispatchSourceFileSystemObject?
    private var permissionCheckTimer: Timer?
    private var accessibilityGranted = false
    private var settingsWindow: SettingsWindow?

    // Tag for dynamic workspace menu items
    private let spaceMenuItemTag = 9000

    // Cached fonts (created once)
    private lazy var monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    private lazy var monoBold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private lazy var titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    // App icon cache for menu bar (bundleID -> resized icon)
    private var appIconCache: [String: NSImage] = [:]

    // Debounce: coalesce rapid status bar updates into one per runloop cycle
    private var needsStatusBarUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted

        if !trusted {
            panelessLog("Accessibility permission not yet granted. Prompting user.")
        }

        setupMenuBar()

        if !accessibilityGranted {
            // Show warning and start periodic re-check
            updateStatusBarPermissionWarning()
            startPermissionCheck()
        } else {
            startWindowManager()
        }

        panelessLog("Ready")
    }

    private func startWindowManager() {
        WindowManager.shared.onSpaceChange = { [weak self] in
            self?.scheduleStatusBarUpdate()
        }
        WindowManager.shared.onFocusChange = { [weak self] in
            self?.scheduleStatusBarUpdate()
        }
        WindowManager.shared.start()

        // Check if Input Monitoring was granted (event tap created successfully).
        // Unlike Accessibility, there's no system API to prompt for it — we
        // detect the failure and guide the user to System Settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if !WindowManager.shared.eventTap.isActive {
                panelessLog("Input Monitoring permission not granted. Keybindings will not work.")
                self?.showInputMonitoringWarning()
            }
        }
        startConfigWatcher()
        updateStatusBar()
    }

    private func startPermissionCheck() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.accessibilityGranted = true
                self.permissionCheckTimer?.invalidate()
                self.permissionCheckTimer = nil
                panelessLog("Accessibility permission granted")
                self.startWindowManager()
            }
        }
    }

    private func updateStatusBarPermissionWarning() {
        guard let button = statusItem?.button else { return }
        let warningStr = NSMutableAttributedString()
        warningStr.append(NSAttributedString(string: "S ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ]))
        warningStr.append(NSAttributedString(string: "No Permission", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemRed
        ]))
        button.attributedTitle = warningStr
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionCheckTimer?.invalidate()
        configWatcherSource?.cancel()
        if accessibilityGranted {
            WindowManager.shared.stop()
        }
    }

    // MARK: - Config File Watcher

    private func startConfigWatcher() {
        let configPath = NSString("~/.config/paneless/config").expandingTildeInPath

        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else {
            panelessLog("Config watcher: couldn't open \(configPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            if WindowManager.shared.suppressNextReload {
                WindowManager.shared.suppressNextReload = false
                panelessLog("Config file change from settings UI, skipping reload")
                return
            }
            panelessLog("Config file changed on disk, reloading")
            self?.performConfigReload()

            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                source.cancel()
                close(fd)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self?.startConfigWatcher()
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        configWatcherSource = source
        source.resume()
        panelessLog("Config watcher active")
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "S"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Dynamic workspace items are added in menuWillOpen
        // Static items below:

        menu.addItem(NSMenuItem.separator())

        if !accessibilityGranted {
            let permItem = NSMenuItem(title: "Grant Accessibility Permission...", action: #selector(openAccessibilitySettings(_:)), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
            menu.addItem(NSMenuItem.separator())
        }

        let retileItem = NSMenuItem(title: "Retile", action: #selector(retile(_:)), keyEquivalent: "")
        retileItem.target = self
        menu.addItem(retileItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let editConfigItem = NSMenuItem(title: "Edit Config...", action: #selector(editConfig(_:)), keyEquivalent: "")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openSettings(_:)), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = .command
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Paneless", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Status Bar Updates

    private func scheduleStatusBarUpdate() {
        guard !needsStatusBarUpdate else { return }
        needsStatusBarUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.needsStatusBarUpdate else { return }
            self.needsStatusBarUpdate = false
            self.updateStatusBar()
        }
    }

    /// Get a cached 18x18 app icon for the menu bar.
    private func cachedAppIcon(bundleID: String?, pid: pid_t) -> NSImage? {
        let cacheKey = bundleID ?? "pid-\(pid)"
        if let cached = appIconCache[cacheKey] { return cached }

        var icon: NSImage?

        // Try bundle ID lookup first (works even if app isn't frontmost)
        if let bid = bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }

        // Fallback: running application icon
        if icon == nil, let app = NSRunningApplication(processIdentifier: pid) {
            icon = app.icon
        }

        guard let img = icon else { return nil }

        // Resize to 18x18 for menu bar (matches system menu bar icon size)
        let size = NSSize(width: 18, height: 18)
        let resized = NSImage(size: size)
        resized.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size),
                 from: NSRect(origin: .zero, size: img.size),
                 operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        resized.isTemplate = false

        appIconCache[cacheKey] = resized
        return resized
    }

    /// Create an inline NSTextAttachment for an app icon.
    private func iconAttachment(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        // y offset aligns icon with text baseline
        attachment.bounds = CGRect(x: 0, y: -3, width: 18, height: 18)
        return NSAttributedString(attachment: attachment)
    }

    /// Collect unique app icons for a workspace (de-duped by bundleID/appName, ordered).
    private func workspaceAppIcons(trackedWindows: [CGWindowID: TrackedWindow]) -> [NSImage] {
        var seen = Set<String>()
        var icons: [NSImage] = []
        for (_, tracked) in trackedWindows {
            let key = tracked.bundleID ?? tracked.appName
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if let icon = cachedAppIcon(bundleID: tracked.bundleID, pid: tracked.pid) {
                icons.append(icon)
            }
        }
        return icons
    }

    func updateStatusBar() {
        guard let button = statusItem?.button else { return }

        let wm = WindowManager.shared
        let wsMgr = WorkspaceManager.shared

        let screen = NSScreen.safeMain
        let monitorID = wsMgr.screenID(for: screen)
        let activeWS = wsMgr.activeWorkspace[monitorID] ?? 1

        // Workspaces to display: active + those with windows
        let withWindows = Set(wsMgr.workspacesWithWindows(on: monitorID))
        let visibleWorkspaces = Set([activeWS]).union(withWindows).sorted()

        var theme = MenuBarTheme.current
        if let c = wm.config.menubarActiveColor { theme.activeWorkspaceColor = c }
        if let c = wm.config.menubarInactiveColor { theme.inactiveWorkspaceColor = c }

        let result = NSMutableAttributedString()

        // Workspace indicators: number + app icons, minimal style
        for (idx, wsNum) in visibleWorkspaces.enumerated() {
            let isActive = wsNum == activeWS

            let label = "\(wsNum)"

            if isActive {
                result.append(NSAttributedString(string: label, attributes: [
                    .font: monoBold, .foregroundColor: theme.activeWorkspaceColor
                ]))
            } else {
                result.append(NSAttributedString(string: label, attributes: [
                    .font: monoFont, .foregroundColor: theme.inactiveWorkspaceColor
                ]))
            }

            // App icons for this workspace
            let icons: [NSImage]
            if isActive {
                icons = workspaceAppIcons(trackedWindows: wm.trackedWindows)
            } else if let ws = wsMgr.workspaces[monitorID]?[wsNum] {
                icons = workspaceAppIcons(trackedWindows: ws.trackedWindows)
            } else {
                icons = []
            }

            if !icons.isEmpty {
                result.append(NSAttributedString(string: " ", attributes: [.font: monoFont]))
                for icon in icons {
                    result.append(iconAttachment(icon))
                }
            }

            if idx < visibleWorkspaces.count - 1 {
                result.append(NSAttributedString(string: "  ", attributes: [.font: monoFont]))
            }
        }

        button.attributedTitle = result
    }

    // MARK: - Actions

    @objc private func retile(_ sender: NSMenuItem) {
        WindowManager.shared.scanCurrentSpace()
    }

    @objc private func reloadConfig(_ sender: NSMenuItem) {
        performConfigReload()
    }

    private func performConfigReload() {
        WindowManager.shared.handleAction(.reloadConfig)
        settingsWindow?.viewModel.loadFromConfig()
        showReloadIndicator()
    }

    private func showReloadIndicator() {
        guard let button = statusItem?.button else { return }
        let current = button.attributedTitle
        let indicator = NSMutableAttributedString(attributedString: current)
        indicator.append(NSAttributedString(string: "  Reloaded", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemGreen
        ]))
        button.attributedTitle = indicator
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.updateStatusBar()
        }
    }

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        let wsNumber = sender.tag - spaceMenuItemTag
        WindowManager.shared.handleAction(.switchWorkspace(wsNumber))
    }

    @objc private func cycleLayout(_ sender: NSMenuItem) {
        WindowManager.shared.handleAction(.cycleLayout)
        updateStatusBar()
    }

    @objc private func editConfig(_ sender: NSMenuItem) {
        let configPath = NSString("~/.config/paneless/config").expandingTildeInPath

        let fm = FileManager.default
        if !fm.fileExists(atPath: configPath) {
            try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            let defaultConfig = """
            # Paneless Configuration
            # Reload with Alt+Shift+R (or your reload_config binding)

            [layout]
            inner_gap = 8
            outer_gap = 8
            animations = true
            # native_animation = false
            # single_window_padding = 0
            # focus_follows_mouse = false
            # force_promotion = false
            # auto_float_dialogs = true
            # focus_follows_app = true

            # Dim unfocused windows using compositor brightness
            # 0.0 = off, 0.15 = subtle, 0.3 = moderate, 0.5 = strong
            dim_unfocused = 0.03

            # Hyperkey: a single key that acts as Ctrl+Opt+Cmd+Shift when held.
            # Works globally, so other apps also see the hyper modifier combo.
            # Recommended: remap Caps Lock to F18 via hidutil, then set hyperkey = f18
            #   hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
            # hyperkey = f18

            [border]
            enabled = false
            width = 2
            active_color = #66ccff
            inactive_color = #444444
            radius = 10

            [rules]
            float = Finder, System Settings, Calculator, Archive Utility, System Preferences
            # exclude = SomeApp
            # sticky = Spotify

            # Window swallowing: terminal launches GUI app → GUI replaces terminal in tile
            # swallow = Ghostty, Terminal, iTerm2, Alacritty, WezTerm, kitty
            # swallow_all = false

            # [app_rules]
            # Arc = left
            # Ghostty = right
            # Slack = workspace 3

            [workspaces]
            # 1 = Main
            # 2 = Browser
            # 3 = Chat

            [bindings]
            # Custom bindings are merged with defaults (custom takes priority).
            # Format: modifier, key = action
            alt+shift, h = focus_prev
            alt+shift, l = focus_next
            alt+shift, j = rotate_next
            alt+shift, k = rotate_prev
            alt+shift, return = swap_master
            alt+shift, space = cycle_layout
            alt+shift, t = toggle_float
            alt+shift, f = toggle_fullscreen
            alt+shift, q = close
            alt+shift, r = reload_config
            alt+shift, equal = increase_gap
            alt+shift, minus = decrease_gap
            alt+shift, rightbracket = grow_focused
            alt+shift, leftbracket = shrink_focused
            alt+shift, m = minimize
            alt+shift, comma = focus_monitor left
            alt+shift, period = focus_monitor right
            cmd+shift, h = position_left
            cmd+shift, l = position_right
            cmd+shift, k = position_up
            cmd+shift, j = position_down
            cmd+shift, f = position_fill

            # Window marks (vim-style):
            # alt+shift, a = set_mark a
            # alt, a = jump_mark a

            # Niri multi-window columns:
            # alt+shift, c = niri_consume
            # alt+shift, x = niri_expel

            # Hyperkey bindings (requires hyperkey = ... in [layout]):
            # hyper, h = focus_prev
            # hyper, l = focus_next
            # hyper, j = rotate_next
            # hyper, k = rotate_prev
            # hyper, f = toggle_fullscreen
            # hyper, t = toggle_float
            # hyper, q = close
            # hyper, space = cycle_layout
            # hyper, 1 = switch_workspace 1
            """
            try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoringSettings(_ sender: NSMenuItem) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInputMonitoringWarning() {
        // Add warning to menu bar
        guard let button = statusItem?.button else { return }
        let current = button.attributedTitle
        let warning = NSMutableAttributedString(attributedString: current)
        warning.append(NSAttributedString(string: "  No Keys", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemOrange
        ]))
        button.attributedTitle = warning

        // Add menu item for granting permission
        if let menu = statusItem?.menu {
            let inputItem = NSMenuItem(title: "Grant Input Monitoring...", action: #selector(openInputMonitoringSettings(_:)), keyEquivalent: "")
            inputItem.target = self
            // Insert before Quit
            let quitIdx = menu.items.firstIndex(where: { $0.title == "Quit Paneless" }) ?? menu.items.count
            menu.insertItem(inputItem, at: quitIdx)
            menu.insertItem(NSMenuItem.separator(), at: quitIdx)
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.showWindow()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate (dynamic workspace items)

extension PanelessAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Remove old dynamic items
        menu.items.filter { $0.tag >= spaceMenuItemTag }.forEach { menu.removeItem($0) }

        let wm = WindowManager.shared
        let wsMgr = WorkspaceManager.shared

        let screen = NSScreen.safeMain
        let monitorID = wsMgr.screenID(for: screen)
        let activeWS = wsMgr.activeWorkspace[monitorID] ?? 1

        // Workspaces to show: active + those with windows
        let withWindows = Set(wsMgr.workspacesWithWindows(on: monitorID))
        let visibleWorkspaces = Set([activeWS]).union(withWindows).sorted()

        // Layout info header
        let layoutName: String
        if wm.config.niriMode {
            let w = wm.config.niriColumnWidth
            if abs(w - 1.0) < 0.01 { layoutName = "Niri (Full)" }
            else if abs(w - 0.5) < 0.01 { layoutName = "Niri (Half)" }
            else if abs(w - 1.0/3.0) < 0.01 { layoutName = "Niri (Third)" }
            else { layoutName = "Niri (\(Int(w * 100))%)" }
        } else {
            let layoutNames = ["Side-by-Side", "Stacked", "Monocle"]
            let variant = wm.layoutEngine.layoutVariant
            layoutName = layoutNames[min(variant, layoutNames.count - 1)]
        }
        let tiledCount = wm.layoutEngine.tiledWindows.count

        let headerItem = NSMenuItem(
            title: "\(layoutName)  \(tiledCount) window\(tiledCount == 1 ? "" : "s")  \(NSScreen.screens.count) monitor\(NSScreen.screens.count == 1 ? "" : "s")",
            action: nil, keyEquivalent: ""
        )
        headerItem.isEnabled = false
        headerItem.tag = spaceMenuItemTag
        menu.insertItem(headerItem, at: 0)

        // Cycle layout action
        let cycleItem = NSMenuItem(title: "Cycle Layout (\(layoutName))", action: #selector(cycleLayout(_:)), keyEquivalent: "")
        cycleItem.target = self
        cycleItem.tag = spaceMenuItemTag + 1
        menu.insertItem(cycleItem, at: 1)

        let separator = NSMenuItem.separator()
        separator.tag = spaceMenuItemTag + 2
        menu.insertItem(separator, at: 2)

        // Virtual workspace switch items
        for (idx, wsNum) in visibleWorkspaces.enumerated() {
            let isActive = wsNum == activeWS
            let count = wsMgr.windowCount(workspace: wsNum, on: monitorID)
            let countStr = count > 0 ? " (\(count))" : ""
            let nameStr: String
            if let name = wm.config.workspaceNames[wsNum] {
                nameStr = "Workspace \(wsNum): \(name)"
            } else {
                nameStr = "Workspace \(wsNum)"
            }
            let title = isActive ? "● \(nameStr)\(countStr)" : "○ \(nameStr)\(countStr)"

            let item = NSMenuItem(title: title, action: #selector(switchToWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.tag = spaceMenuItemTag + wsNum
            if isActive { item.state = .on }
            menu.insertItem(item, at: 3 + idx)
        }

        let sepIdx = 3 + visibleWorkspaces.count
        let sep = NSMenuItem.separator()
        sep.tag = spaceMenuItemTag + 100
        menu.insertItem(sep, at: sepIdx)
    }
}
