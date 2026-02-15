import Cocoa

// MARK: - Catppuccin Menu Bar Theme

private struct MenuBarTheme {
    let layoutColor: NSColor
    let activeWorkspaceColor: NSColor
    let inactiveWorkspaceColor: NSColor
    let titleColor: NSColor

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

class SpaceyAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var configWatcherSource: DispatchSourceFileSystemObject?

    // Tag for dynamic workspace menu items
    private let spaceMenuItemTag = 9000

    // Cached fonts (created once)
    private lazy var monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private lazy var monoBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private lazy var titleFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    // Debounce: coalesce rapid status bar updates into one per runloop cycle
    private var needsStatusBarUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            spaceyLog("Accessibility permission not yet granted. Prompting user.")
        }

        setupMenuBar()

        WindowManager.shared.onSpaceChange = { [weak self] in
            self?.scheduleStatusBarUpdate()
        }
        WindowManager.shared.onFocusChange = { [weak self] in
            self?.scheduleStatusBarUpdate()
        }
        WindowManager.shared.start()
        startConfigWatcher()
        updateStatusBar()

        spaceyLog("Ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        configWatcherSource?.cancel()
        WindowManager.shared.stop()
    }

    // MARK: - Config File Watcher

    private func startConfigWatcher() {
        let configPath = NSString("~/.config/spacey/config").expandingTildeInPath

        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else {
            spaceyLog("Config watcher: couldn't open \(configPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            spaceyLog("Config file changed on disk, reloading")
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
        spaceyLog("Config watcher active")
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

        let retileItem = NSMenuItem(title: "Retile", action: #selector(retile(_:)), keyEquivalent: "")
        retileItem.target = self
        menu.addItem(retileItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let editConfigItem = NSMenuItem(title: "Edit Config...", action: #selector(editConfig(_:)), keyEquivalent: "")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Spacey", action: #selector(quit(_:)), keyEquivalent: "q")
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

    func updateStatusBar() {
        guard let button = statusItem?.button else { return }

        let wm = WindowManager.shared
        let wsMgr = WorkspaceManager.shared

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let monitorID = wsMgr.screenID(for: screen)
        let activeWS = wsMgr.activeWorkspace[monitorID] ?? 1

        // Workspaces to display: active + those with windows
        let withWindows = Set(wsMgr.workspacesWithWindows(on: monitorID))
        let visibleWorkspaces = Set([activeWS]).union(withWindows).sorted()

        let theme = MenuBarTheme.current

        // Layout indicator: []=  TTT  [M]
        let layoutIcons = ["[]=", "TTT", "[M]"]
        let variant = wm.layoutEngine.layoutVariant
        let layoutStr = layoutIcons[min(variant, layoutIcons.count - 1)]

        // Active window title
        var windowTitle = ""
        if let focusedID = wm.focusedWindowID,
           let tracked = wm.trackedWindows[focusedID] {
            if let element = wm.axElements[focusedID],
               let title = AccessibilityBridge.getTitle(of: element), !title.isEmpty {
                windowTitle = title
            } else {
                windowTitle = tracked.appName
            }
            if windowTitle.count > 40 {
                windowTitle = String(windowTitle.prefix(37)) + "..."
            }
        }

        let result = NSMutableAttributedString()

        if !windowTitle.isEmpty {
            result.append(NSAttributedString(string: "\(windowTitle)  ", attributes: [
                .font: titleFont, .foregroundColor: theme.titleColor
            ]))
        }

        result.append(NSAttributedString(string: "\(layoutStr)  ", attributes: [
            .font: monoFont, .foregroundColor: theme.layoutColor
        ]))

        // Virtual workspace numbers
        for (idx, wsNum) in visibleWorkspaces.enumerated() {
            let isActive = wsNum == activeWS
            let num = "\(wsNum)"

            if isActive {
                result.append(NSAttributedString(string: num, attributes: [
                    .font: monoBold, .foregroundColor: theme.activeWorkspaceColor
                ]))
            } else {
                result.append(NSAttributedString(string: num, attributes: [
                    .font: monoFont, .foregroundColor: theme.inactiveWorkspaceColor
                ]))
            }

            if idx < visibleWorkspaces.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: [.font: monoFont]))
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
        let configPath = NSString("~/.config/spacey/config").expandingTildeInPath

        let fm = FileManager.default
        if !fm.fileExists(atPath: configPath) {
            try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            let defaultConfig = """
            [layout]
            inner_gap = 8
            outer_gap = 8
            sketchybar_height = 0

            [border]
            enabled = false
            width = 2
            active_color = #66ccff
            inactive_color = #444444
            radius = 10

            [rules]
            float = Finder, System Settings, Calculator, Archive Utility, System Preferences
            # [bindings]
            # alt+shift, h = focus_left
            # alt+shift, l = focus_right
            # alt+shift, return = swap_master
            # alt+shift, space = toggle_float
            # alt+shift, f = toggle_fullscreen
            # alt+shift, q = close
            """
            try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate (dynamic workspace items)

extension SpaceyAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Remove old dynamic items
        menu.items.filter { $0.tag >= spaceMenuItemTag }.forEach { menu.removeItem($0) }

        let wm = WindowManager.shared
        let wsMgr = WorkspaceManager.shared

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let monitorID = wsMgr.screenID(for: screen)
        let activeWS = wsMgr.activeWorkspace[monitorID] ?? 1

        // Workspaces to show: active + those with windows
        let withWindows = Set(wsMgr.workspacesWithWindows(on: monitorID))
        let visibleWorkspaces = Set([activeWS]).union(withWindows).sorted()

        // Layout info header
        let layoutNames = ["Side-by-Side", "Stacked", "Monocle"]
        let variant = wm.layoutEngine.layoutVariant
        let layoutName = layoutNames[min(variant, layoutNames.count - 1)]
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
            let title = isActive ? "● Workspace \(wsNum)\(countStr)" : "○ Workspace \(wsNum)\(countStr)"

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
