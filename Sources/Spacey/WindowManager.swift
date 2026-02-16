import Cocoa

class WindowManager: WindowObserverDelegate {
    static let shared = WindowManager()

    var config: SpaceyConfig
    let layoutEngine: LayoutEngine
    let observer: WindowObserver
    let eventTap: EventTap

    var onSpaceChange: (() -> Void)?
    var onFocusChange: (() -> Void)?

    var trackedWindows: [CGWindowID: TrackedWindow] = [:]
    var axElements: [CGWindowID: AXUIElement] = [:]
    var floatingWindows: Set<CGWindowID> = []
    var fullscreenWindows: Set<CGWindowID> = []
    var stickyWindows: Set<CGWindowID> = []
    var focusedWindowID: CGWindowID?

    private var mouseMonitor: Any?
    private var lastMouseFocusTime: Date = .distantPast
    private var dimmedWindows: Set<CGWindowID> = []
    private var dimOverlays: [CGWindowID: NSWindow] = [:]
    private var clickMonitor: Any?
    private var clickDimWorkItem: DispatchWorkItem?
    private var resizeMonitor: Any?
    private var isResizing = false
    private var resizeStartPos: CGFloat = 0
    private var resizeInitialRatio: CGFloat = 0.5

    // Minimized windows (hidden but tracked in workspace)
    private var minimizedWindows: Set<CGWindowID> = []

    // Scratchpad state
    private var scratchpadWindowID: CGWindowID?
    private var scratchpadVisible = false

    // Window marks (vim-style: key -> windowID)
    private var windowMarks: [String: CGWindowID] = [:]

    // Per-workspace layout memory
    private var workspaceLayouts: [String: Int] = [:]  // "monitorID-wsNum" -> layoutVariant

    // Focus flash
    private var flashOverlay: NSWindow?
    private var flashWorkItem: DispatchWorkItem?

    // Drag-to-reorder
    private var dragMonitor: Any?
    private var dragStartWindowID: CGWindowID?

    private init() {
        self.config = SpaceyConfig.load()
        self.layoutEngine = LayoutEngine(config: config)
        self.observer = WindowObserver()
        self.eventTap = EventTap()
    }

    func start() {
        BorderManager.shared.config = config.border
        eventTap.keyBindings = config.keyBindings
        Animator.shared.enabled = config.animations

        observer.delegate = self
        observer.start()

        eventTap.actionHandler = { [weak self] action in
            self?.handleAction(action)
        }
        eventTap.start()

        scanCurrentSpace()

        // Check for orphaned hidden windows from a previous crash and restore them
        restoreOrphanedWindows()

        // Reset any stale CGS transforms from a previous crash mid-animation
        let allWindowIDs = SpaceManager.getWindowsOnCurrentSpace()
        Animator.shared.resetTransforms(for: allWindowIDs)

        // Initialize virtual workspace 1 with the scanned windows
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        WorkspaceManager.shared.activeWorkspace[monitorID] = 1
        saveWorkspaceState(workspace: 1, monitor: monitorID)
        spaceyLog("Initialized workspace 1 on \(monitorID) with \(layoutEngine.tiledWindows.count) tiled windows")

        // Restore windows to their saved workspaces from a previous session
        WorkspacePersistence.restoreWorkspaceAssignments()

        // Smart retile on display change (monitor connected/disconnected/resolution change)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Focus follows mouse
        if config.focusFollowsMouse {
            startFocusFollowsMouse()
        }

        // Global click monitor to refresh dimming after macOS finishes window activation
        setupClickMonitor()

        // Mouse drag resize between tiled windows
        setupResizeMonitor()

        // Ctrl+drag to reorder tiled windows
        setupDragMonitor()

        // Force ProMotion to stay at max refresh rate (120Hz)
        if config.forceProMotion {
            startDisplayLink()
        }

        spaceyLog("Spacey started (monitors: \(NSScreen.screens.count), bindings: \(config.keyBindings.count))")
    }

    func stop() {
        // Save workspace state before shutting down
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        saveWorkspaceState(workspace: currentWS, monitor: monitorID)
        WorkspacePersistence.saveImmediate()

        Animator.shared.cancelAll()
        BorderManager.shared.removeAll()
        restoreAllDimming()
        stopFocusFollowsMouse()
        stopResizeMonitor()
        stopDisplayLink()
        NotificationCenter.default.removeObserver(self)
        observer.stop()
        eventTap.stop()
        spaceyLog("Spacey stopped")
    }

    // MARK: - Action Dispatch

    func handleAction(_ action: WMAction) {
        switch action {
        case .focusDirection(let dir):      focusInDirection(dir)
        case .focusNext:                    focusCycle(forward: true)
        case .focusPrev:                    focusCycle(forward: false)
        case .swapWithMaster:               swapWithMaster()
        case .toggleFloat:                  toggleFloat()
        case .toggleFullscreen:             toggleFullscreen()
        case .closeFocused:                 closeFocused()
        case .focusMonitor(let dir):        focusMonitor(dir)
        case .moveToMonitor(let dir):       moveToMonitor(dir)
        case .positionLeft:                 positionFocused(.left)
        case .positionRight:                positionFocused(.right)
        case .positionUp:                   positionFocused(.up)
        case .positionDown:                 positionFocused(.down)
        case .positionFill:                 positionFocused(.fill)
        case .positionCenter:               positionFocused(.center)
        case .rotateNext:                   rotateWindows(forward: true)
        case .rotatePrev:                   rotateWindows(forward: false)
        case .cycleLayout:                  cycleLayout()
        case .increaseGap:                  adjustGap(by: 4)
        case .decreaseGap:                  adjustGap(by: -4)
        case .growFocused:                  adjustSplitRatio(by: 0.05)
        case .shrinkFocused:                adjustSplitRatio(by: -0.05)
        case .retile:
            layoutEngine.splitRatio = 0.5
            layoutEngine.layoutVariant = 0
            scanCurrentSpace()
        case .reloadConfig:                 reloadConfig()
        case .switchWorkspace(let n):       switchVirtualWorkspace(n)
        case .moveToWorkspace(let n):       moveToVirtualWorkspace(n)
        case .minimizeToWorkspace:          minimizeFocused()
        case .toggleScratchpad:             toggleScratchpad()
        case .setMark(let key):             setWindowMark(key)
        case .jumpToMark(let key):          jumpToWindowMark(key)
        }
    }

    // MARK: - Focus Navigation

    private func focusInDirection(_ direction: Direction) {
        var currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()

        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())

        // If the focused window isn't in our tiled layout (common with Electron apps
        // like Arc/Cursor that have internal windows), fall back to the first tiled window.
        if let cid = currentID, layouts.first(where: { $0.0 == cid }) == nil {
            currentID = layoutEngine.tiledWindows.first
            if let fid = currentID { focusedWindowID = fid }
        }

        guard let currentID = currentID else { return }

        guard let neighborID = layoutEngine.getNeighbor(of: currentID, direction: direction, layouts: layouts)
        else { return }

        if let element = axElements[neighborID], let tracked = trackedWindows[neighborID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = neighborID
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
            flashFocusedWindow()
            onFocusChange?()
        }
    }

    /// Cycle focus through tiled AND floating windows in list order (wraps around).
    private func focusCycle(forward: Bool) {
        // Build a combined list: tiled windows first, then floating windows
        let allWindows = layoutEngine.tiledWindows + Array(floatingWindows).sorted()
        guard allWindows.count >= 2 else { return }

        let currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        let currentIdx = currentID.flatMap { allWindows.firstIndex(of: $0) } ?? 0

        let nextIdx: Int
        if forward {
            nextIdx = (currentIdx + 1) % allWindows.count
        } else {
            nextIdx = (currentIdx - 1 + allWindows.count) % allWindows.count
        }

        let targetID = allWindows[nextIdx]
        if let element = axElements[targetID], let tracked = trackedWindows[targetID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = targetID
            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
            flashFocusedWindow()
            onFocusChange?()
        }
    }

    // MARK: - Multi-Monitor

    private func focusMonitor(_ direction: Direction) {
        guard let currentScreen = NSScreen.main,
              let targetScreen = SpaceManager.neighborScreen(of: currentScreen, direction: direction)
        else { return }

        for (windowID, tracked) in trackedWindows {
            guard let element = axElements[windowID],
                  !floatingWindows.contains(windowID)
            else { continue }

            if let frame = AccessibilityBridge.getFrame(of: element) {
                let screenForWindow = SpaceManager.screen(containing: CGPoint(x: frame.midX, y: frame.midY))
                if screenForWindow == targetScreen {
                    AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    focusedWindowID = windowID
                    return
                }
            }
        }
    }

    private func moveToMonitor(_ direction: Direction) {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID],
              let currentFrame = AccessibilityBridge.getFrame(of: element)
        else { return }

        let currentScreen = SpaceManager.screen(containing: currentFrame.origin) ?? NSScreen.main!
        guard let targetScreen = SpaceManager.neighborScreen(of: currentScreen, direction: direction) else { return }

        let targetVisible = targetScreen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
        let axY = primaryHeight - targetVisible.origin.y - targetVisible.size.height

        let newFrame = CGRect(
            x: targetVisible.origin.x + (targetVisible.width - currentFrame.width) / 2,
            y: axY + (targetVisible.height - currentFrame.height) / 2,
            width: currentFrame.width,
            height: currentFrame.height
        )
        AccessibilityBridge.setFrame(of: element, to: newFrame)
    }

    // MARK: - Swap / Layout

    private func swapWithMaster() {
        guard let currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }
        layoutEngine.swapWithFirst(currentID)
        retile()
    }

    private func rotateWindows(forward: Bool) {
        guard layoutEngine.tiledWindows.count >= 2 else { return }
        if forward {
            layoutEngine.rotateNext()
        } else {
            layoutEngine.rotatePrev()
        }
        retile()

        // Re-focus the same window at its new position so focus follows the move
        if let fid = focusedWindowID,
           let element = axElements[fid],
           let tracked = trackedWindows[fid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
        }
    }

    // MARK: - Float / Fullscreen

    private func toggleFloat() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        if floatingWindows.contains(windowID) {
            floatingWindows.remove(windowID)
            layoutEngine.insert(windowID: windowID, afterFocused: nil)
        } else {
            floatingWindows.insert(windowID)
            layoutEngine.remove(windowID: windowID)
        }
        retile()
    }

    private func toggleFullscreen() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID]
        else { return }

        if fullscreenWindows.contains(windowID) {
            fullscreenWindows.remove(windowID)
            layoutEngine.insert(windowID: windowID, afterFocused: nil)
            retile()
        } else {
            fullscreenWindows.insert(windowID)
            layoutEngine.remove(windowID: windowID)
            // Use the full visible screen (menu bar + dock respected, no Spacey gaps)
            let screen = NSScreen.safeMain
            let visibleFrame = screen.visibleFrame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let axY = primaryHeight - visibleFrame.origin.y - visibleFrame.size.height
            let fullFrame = CGRect(x: visibleFrame.origin.x, y: axY,
                                   width: visibleFrame.width, height: visibleFrame.height)
            AccessibilityBridge.setFrame(of: element, to: fullFrame)
            retile()
        }
    }

    // MARK: - Window Positioning

    private enum Position { case left, right, up, down, fill, center }

    private func positionFocused(_ position: Position) {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        switch position {
        case .left:
            // Move focused window to first position in layout
            guard layoutEngine.contains(windowID) else { return }
            layoutEngine.tiledWindows.removeAll { $0 == windowID }
            layoutEngine.tiledWindows.insert(windowID, at: 0)
            retile()

        case .right:
            // Move focused window to last position in layout
            guard layoutEngine.contains(windowID) else { return }
            layoutEngine.tiledWindows.removeAll { $0 == windowID }
            layoutEngine.tiledWindows.append(windowID)
            retile()

        case .up:
            // Swap focused window one position earlier
            guard let idx = layoutEngine.tiledWindows.firstIndex(of: windowID), idx > 0 else { return }
            layoutEngine.tiledWindows.swapAt(idx, idx - 1)
            retile()

        case .down:
            // Swap focused window one position later
            guard let idx = layoutEngine.tiledWindows.firstIndex(of: windowID),
                  idx < layoutEngine.tiledWindows.count - 1 else { return }
            layoutEngine.tiledWindows.swapAt(idx, idx + 1)
            retile()

        case .fill:
            guard let element = axElements[windowID] else { return }
            let region = getTilingRegion()
            let gap = config.innerGap
            let halfGap = gap / 2
            let frame = CGRect(
                x: region.x + halfGap,
                y: region.y + halfGap,
                width: max(region.width - gap, 100),
                height: max(region.height - gap, 100)
            )
            AccessibilityBridge.setFrame(of: element, to: frame)

        case .center:
            guard let element = axElements[windowID] else { return }
            let region = getTilingRegion()
            let w = region.width * 0.6
            let h = region.height * 0.7
            let frame = CGRect(
                x: region.x + (region.width - w) / 2,
                y: region.y + (region.height - h) / 2,
                width: w,
                height: h
            )
            AccessibilityBridge.setFrame(of: element, to: frame)
        }
    }

    // MARK: - Close

    private func closeFocused() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID]
        else { return }

        let wasTiled = layoutEngine.contains(windowID)
        let closingFrame = AccessibilityBridge.getFrame(of: element) ?? .zero

        if wasTiled && closingFrame != .zero {
            // Animated close: scale down + fade the closing window
            // while remaining windows redistribute simultaneously

            // Remove from layout so we can calculate remaining layout
            layoutEngine.remove(windowID: windowID)

            // Build transitions for remaining windows
            let region = getTilingRegion()
            let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
                guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
                return (wid, el, t.pid)
            }
            let targetFrames = NativeTiling.calculateFrames(
                count: windows.count, region: region, gap: config.innerGap,
                singleWindowPadding: config.singleWindowPadding,
                splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant
            )

            var transitions: [Animator.Transition] = []
            for (i, w) in windows.enumerated() where i < targetFrames.count {
                let currentFrame = AccessibilityBridge.getFrame(of: w.element) ?? targetFrames[i]
                transitions.append(Animator.Transition(
                    windowID: w.windowID, element: w.element,
                    startFrame: currentFrame, targetFrame: targetFrames[i]
                ))
            }

            // Animate close + redistribute, then actually close the window
            Animator.shared.animateWithClose(
                redistributeTransitions: transitions,
                closingWindowID: windowID,
                closingFrame: closingFrame
            ) { [weak self] in
                AccessibilityBridge.close(window: element)
                // Restore alpha in case the window survives (e.g. "Save?" dialog)
                let conn = CGSMainConnectionID()
                CGSSetWindowAlpha(conn, windowID, 1.0)
                self?.windowDestroyed(windowID: windowID)
            }
        } else {
            AccessibilityBridge.close(window: element)
        }
    }

    // MARK: - Config Reload

    private func reloadConfig() {
        config = SpaceyConfig.load()
        layoutEngine.config = config
        BorderManager.shared.config = config.border
        eventTap.keyBindings = config.keyBindings

        // Update focus-follows-mouse
        stopFocusFollowsMouse()
        if config.focusFollowsMouse {
            startFocusFollowsMouse()
        }

        // Update dimming
        if config.dimUnfocused <= 0 {
            restoreAllDimming()
        }

        // Update animations
        Animator.shared.enabled = config.animations

        // Update ProMotion forcing
        if config.forceProMotion {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }

        scanCurrentSpace()
        spaceyLog("Config reloaded")
    }

    // MARK: - Tiling

    func retile() {
        let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
            guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
            return (wid, el, t.pid)
        }

        let region = getTilingRegion()

        // Native macOS compositor tiling: GPU-driven animation, no content redraw.
        // Only used when explicitly enabled — incompatible with gaps.
        if config.nativeAnimation &&
           NativeTiling.canUseMenuTiling(count: windows.count, splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant) {
            let menuSuccess = NativeTiling.applyViaMenu(
                windows: windows,
                variant: layoutEngine.layoutVariant
            )

            if menuSuccess {
                // Restore focus to the originally focused window (applyViaMenu cycles focus)
                if let focusedID = focusedWindowID,
                   let element = axElements[focusedID],
                   let tracked = trackedWindows[focusedID] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    }
                }
            } else {
                spaceyLog("retile: menu tiling failed, falling back to AX frames")
                NativeTiling.applyLayout(
                    windows: windows, region: region, gap: config.innerGap,
                    singleWindowPadding: config.singleWindowPadding,
                    splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant
                )
            }
        } else {
            NativeTiling.applyLayout(
                windows: windows, region: region, gap: config.innerGap,
                singleWindowPadding: config.singleWindowPadding,
                splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant
            )
        }

        let layouts = layoutEngine.calculateFrames(in: region)
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
    }

    /// Retile with a scale-in effect for a newly created window.
    /// Avoids redundant AX getFrame calls by using calculated start frames directly.
    private func retileWithScaleIn(newWindowID: CGWindowID) {
        let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
            guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
            return (wid, el, t.pid)
        }
        guard !windows.isEmpty else { return }

        let region = getTilingRegion()
        let targetFrames = NativeTiling.calculateFrames(
            count: windows.count, region: region, gap: config.innerGap,
            singleWindowPadding: config.singleWindowPadding,
            splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant
        )

        var transitions: [Animator.Transition] = []
        for (i, w) in windows.enumerated() where i < targetFrames.count {
            let target = targetFrames[i]

            let startFrame: CGRect
            let isNew: Bool
            if w.windowID == newWindowID {
                // New window: start from 87% centered — Hyprland popin 87% effect
                let scale: CGFloat = 0.87
                startFrame = CGRect(
                    x: target.midX - target.width * scale / 2,
                    y: target.midY - target.height * scale / 2,
                    width: target.width * scale,
                    height: target.height * scale
                )
                isNew = true
            } else {
                startFrame = AccessibilityBridge.getFrame(of: w.element) ?? target
                isNew = false
            }

            transitions.append(Animator.Transition(
                windowID: w.windowID, element: w.element,
                startFrame: startFrame, targetFrame: target,
                isNewWindow: isNew
            ))
        }

        Animator.shared.animate(transitions)

        let layouts = layoutEngine.calculateFrames(in: region)
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
    }

    func getTilingRegion(for screen: NSScreen? = nil) -> TilingRegion {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = screen else {
            return TilingRegion(x: 0, y: 0, width: 1920, height: 1080)
        }

        let visibleFrame = screen.visibleFrame
        let gap = config.outerGap
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axY = primaryHeight - visibleFrame.origin.y - visibleFrame.size.height

        return TilingRegion(
            x: visibleFrame.origin.x + gap,
            y: axY + gap,
            width: visibleFrame.size.width - gap * 2,
            height: visibleFrame.size.height - gap * 2
        )
    }

    // MARK: - Border Updates

    private func updateBorders(layouts: [(CGWindowID, CGRect)]) {
        guard config.border.enabled else { return }

        let focusedID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        if let fid = focusedID, let layout = layouts.first(where: { $0.0 == fid }) {
            BorderManager.shared.updateFocus(windowID: fid, frame: layout.1)
        } else {
            BorderManager.shared.updateFocus(windowID: nil, frame: nil)
        }
    }

    // MARK: - Window Scanning

    func scanCurrentSpace() {
        layoutEngine.tiledWindows.removeAll()
        trackedWindows.removeAll()
        axElements.removeAll()
        floatingWindows.removeAll()
        fullscreenWindows.removeAll()
        stickyWindows.removeAll()

        let allWindowIDs = SpaceManager.getWindowsOnCurrentSpace()
        let hiddenIDs = WorkspaceManager.shared.allHiddenWindowIDs()
        let windowIDs = allWindowIDs.filter { !hiddenIDs.contains($0) }
        // Known windows = active workspace windows + hidden windows (so hidden aren't re-discovered)
        var allKnown = Set(allWindowIDs)
        allKnown.formUnion(hiddenIDs)
        observer.syncKnownWindows(allKnown)

        for windowID in windowIDs {
            guard let info = SpaceManager.getWindowInfo(windowID) else { continue }
            guard !appMatchesRule(info.appName, bundleID: info.bundleID, rules: config.excludeApps) else { continue }

            var shouldFloat = appMatchesRule(info.appName, bundleID: info.bundleID, rules: config.floatApps)

            let tracked = TrackedWindow(
                windowID: windowID,
                pid: info.pid,
                appName: info.appName,
                bundleID: info.bundleID,
                isFloating: shouldFloat,
                frame: info.frame
            )
            trackedWindows[windowID] = tracked

            for (element, wid) in AccessibilityBridge.getWindows(for: info.pid) {
                if wid == windowID {
                    axElements[windowID] = element
                    break
                }
            }

            // Auto-float dialogs and small windows
            if !shouldFloat, config.autoFloatDialogs, let element = axElements[windowID] {
                if AccessibilityBridge.isDialog(element) || AccessibilityBridge.isSmallWindow(element) {
                    shouldFloat = true
                }
            }

            // Mark as sticky if app matches sticky rules
            if appMatchesRule(info.appName, bundleID: info.bundleID, rules: config.stickyApps) {
                stickyWindows.insert(windowID)
            }

            if shouldFloat {
                floatingWindows.insert(windowID)
            } else if axElements[windowID] != nil {
                layoutEngine.insert(windowID: windowID, afterFocused: nil)
            } else {
                trackedWindows.removeValue(forKey: windowID)
            }
        }

        focusedWindowID = AccessibilityBridge.getFocusedWindowID()
        retile()
    }

    // MARK: - WindowObserverDelegate

    /// Restore window alpha that was pre-emptively set to 0 by the AX observer.
    /// Called for windows that won't be animated (floating, excluded, etc.).
    private func restoreWindowAlpha(_ windowID: CGWindowID) {
        let conn = CGSMainConnectionID()
        CGSSetWindowAlpha(conn, windowID, 1.0)
    }

    func windowCreated(windowID: CGWindowID, pid: pid_t, appName: String) {
        guard trackedWindows[windowID] == nil else {
            restoreWindowAlpha(windowID)
            return
        }
        // Skip windows hidden on other virtual workspaces
        guard !WorkspaceManager.shared.isWindowHiddenOnOtherWorkspace(windowID) else {
            restoreWindowAlpha(windowID)
            return
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard !appMatchesRule(appName, bundleID: bundleID, rules: config.excludeApps) else {
            restoreWindowAlpha(windowID)
            return
        }

        var shouldFloat = appMatchesRule(appName, bundleID: bundleID, rules: config.floatApps)

        let tracked = TrackedWindow(
            windowID: windowID,
            pid: pid,
            appName: appName,
            bundleID: bundleID,
            isFloating: shouldFloat
        )
        trackedWindows[windowID] = tracked

        for (element, wid) in AccessibilityBridge.getWindows(for: pid) {
            if wid == windowID {
                axElements[windowID] = element
                break
            }
        }

        // Check if this is the scratchpad window we just launched
        checkScratchpadPending(windowID: windowID, appName: appName, bundleID: bundleID)
        if scratchpadWindowID == windowID {
            restoreWindowAlpha(windowID)
            return  // Scratchpad handles its own setup
        }

        // Auto-float dialogs and small windows
        if !shouldFloat, config.autoFloatDialogs, let element = axElements[windowID] {
            if AccessibilityBridge.isDialog(element) || AccessibilityBridge.isSmallWindow(element) {
                shouldFloat = true
                spaceyLog("Auto-floating dialog/small window: \(appName) (\(windowID))")
            }
        }

        // Auto-float secondary windows from apps that already have a tiled window.
        // Catches: settings panels, popups, tab pickers, address bar suggestions, etc.
        if !shouldFloat, let element = axElements[windowID] {
            let appAlreadyTiled = layoutEngine.tiledWindows.contains { tid in
                trackedWindows[tid]?.pid == pid
            }
            if appAlreadyTiled {
                let title = AccessibilityBridge.getTitle(of: element)
                let isUntitled = title == nil || title?.isEmpty == true

                // Check if the window is smaller than 70% of the tiling region
                // (settings panels, preferences, etc. are typically smaller)
                var isSmallerThanRegion = false
                if let frame = AccessibilityBridge.getFrame(of: element) {
                    let region = getTilingRegion()
                    isSmallerThanRegion = frame.width < region.width * 0.7 || frame.height < region.height * 0.7
                }

                if isUntitled || isSmallerThanRegion {
                    shouldFloat = true
                    spaceyLog("Auto-floating secondary window from \(appName) (\(windowID))")
                }
            }
        }

        // Mark as sticky if app matches sticky rules
        if appMatchesRule(appName, bundleID: bundleID, rules: config.stickyApps) {
            stickyWindows.insert(windowID)
        }

        // Per-app workspace assignment: auto-move to specified workspace
        let targetWorkspace = config.appWorkspaceRules[appName]
            ?? (bundleID.flatMap { config.appWorkspaceRules[$0] })
        if let target = targetWorkspace {
            let screen = NSScreen.safeMain
            let monitorID = WorkspaceManager.shared.screenID(for: screen)
            let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
            if target != currentWS {
                // Move directly to target workspace without showing on current
                let screenFrame = screenFrameInAX(for: screen)
                if let element = axElements[windowID] {
                    WorkspaceManager.shared.hideWindow(windowID, element: element, screenFrame: screenFrame)
                }

                var targetWS = WorkspaceManager.shared.workspaces[monitorID]?[target] ?? VirtualWorkspace()
                targetWS.trackedWindows[windowID] = tracked
                if let element = axElements[windowID] {
                    targetWS.axElements[windowID] = element
                }
                if shouldFloat {
                    targetWS.floatingWindows.insert(windowID)
                } else {
                    targetWS.tiledWindows.append(windowID)
                }
                WorkspaceManager.shared.workspaces[monitorID, default: [:]][target] = targetWS

                // Remove from current workspace tracking
                trackedWindows.removeValue(forKey: windowID)
                axElements.removeValue(forKey: windowID)

                // Update observer to know about this hidden window
                var known = observer.currentKnownWindows
                known.insert(windowID)
                observer.syncKnownWindows(known)

                spaceyLog("Auto-moved \(appName) (\(windowID)) to workspace \(target)")
                return
            }
        }

        if shouldFloat {
            floatingWindows.insert(windowID)
            restoreWindowAlpha(windowID)
        } else if axElements[windowID] != nil {
            layoutEngine.insert(windowID: windowID, afterFocused: focusedWindowID)

            // Apply per-app layout rules (e.g. "Arc = left" puts Arc at index 0)
            let ruleKey = config.appLayoutRules[appName]
                ?? (bundleID.flatMap { config.appLayoutRules[$0] })
            if let rule = ruleKey {
                switch rule {
                case "left":
                    layoutEngine.tiledWindows.removeAll { $0 == windowID }
                    layoutEngine.tiledWindows.insert(windowID, at: 0)
                case "right":
                    layoutEngine.tiledWindows.removeAll { $0 == windowID }
                    layoutEngine.tiledWindows.append(windowID)
                default: break
                }
            }

            // macOS gives focus to newly created windows, so update our tracking
            // to match. This ensures dim overlays and borders reflect actual focus.
            focusedWindowID = windowID

            // Immediately hide the new window so the user never sees it at the
            // app's default position. The Animator will fade it in at the correct
            // tiled position with the Hyprland popin effect.
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, windowID, 0.0)

            // Hyprland-style scale-in: calculate 87% centered start frame for the new window.
            // The GPU Animator will handle the scale-up + fade-in from center.
            retileWithScaleIn(newWindowID: windowID)
        } else {
            trackedWindows.removeValue(forKey: windowID)
            restoreWindowAlpha(windowID)
        }
    }

    func windowDestroyed(windowID: CGWindowID) {
        guard trackedWindows[windowID] != nil else { return }

        // Clean up scratchpad if its window was closed
        if windowID == scratchpadWindowID {
            scratchpadWindowID = nil
            scratchpadVisible = false
        }

        // Clean up minimized state
        minimizedWindows.remove(windowID)

        // Clean up any marks pointing to this window
        windowMarks = windowMarks.filter { $0.value != windowID }

        let destroyedPid = trackedWindows[windowID]?.pid

        trackedWindows.removeValue(forKey: windowID)
        axElements.removeValue(forKey: windowID)
        floatingWindows.remove(windowID)
        fullscreenWindows.remove(windowID)
        stickyWindows.remove(windowID)
        dimmedWindows.remove(windowID)
        if let overlay = dimOverlays.removeValue(forKey: windowID) {
            overlay.orderOut(nil)
        }

        let wasTiled = layoutEngine.contains(windowID)
        if wasTiled {
            layoutEngine.remove(windowID: windowID)
            retile()
        }

        // Always try to focus a remaining tiled window after a tiled window is destroyed.
        // macOS may keep focus on the app that owned the closed window
        // (e.g. Ghostty/Arc with windows on other spaces), even if the destroyed
        // window wasn't tracked as focusedWindowID (Cmd+W bypass).
        if wasTiled {
            // Check if current focus is still on the destroyed window's app
            // and that app has no more tiled windows on this space.
            let appStillTiled = layoutEngine.tiledWindows.contains { tid in
                trackedWindows[tid]?.pid == destroyedPid
            }

            let shouldRefocus = focusedWindowID == windowID
                || focusedWindowID == nil
                || !appStillTiled

            if shouldRefocus {
                if let firstWid = layoutEngine.tiledWindows.first,
                   let element = axElements[firstWid], let tracked = trackedWindows[firstWid] {
                    AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    focusedWindowID = firstWid
                } else if layoutEngine.tiledWindows.isEmpty && floatingWindows.isEmpty {
                    // No windows left on this workspace — focus Finder/desktop
                    focusDesktop()
                }
            }

            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
        }
    }

    func spaceChanged() {
        // With virtual workspaces, native space changes are a no-op.
        // All workspace switching is handled by switchVirtualWorkspace().
        spaceyLog("Native space change detected (ignored — using virtual workspaces)")
    }

    func focusChanged() {
        guard let newFocusedID = AccessibilityBridge.getFocusedWindowID(),
              newFocusedID != focusedWindowID,
              trackedWindows[newFocusedID] != nil
        else { return }
        applyFocusChange(newFocusedID)
    }

    func focusChanged(windowID: CGWindowID) {
        guard windowID != focusedWindowID,
              trackedWindows[windowID] != nil
        else {
            // Fallback: the notification element might be an app ref, not a window.
            // Try the old NSWorkspace path.
            focusChanged()
            return
        }
        applyFocusChange(windowID)
    }

    private func applyFocusChange(_ newFocusedID: CGWindowID) {
        focusedWindowID = newFocusedID
        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
        flashFocusedWindow()
        onFocusChange?()
    }

    func applicationLaunched(pid: pid_t, name: String) {}

    func applicationTerminated(pid: pid_t, name: String) {
        let toRemove = trackedWindows.filter { $0.value.pid == pid }.map { $0.key }
        for windowID in toRemove {
            windowDestroyed(windowID: windowID)
        }
    }

    // MARK: - Cycle Layout

    private func cycleLayout() {
        layoutEngine.cycleVariant()
        let names = ["side-by-side", "stacked", "monocle"]
        spaceyLog("Layout: \(names[layoutEngine.layoutVariant])")

        // Save layout variant for this workspace
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        workspaceLayouts["\(monitorID)-\(currentWS)"] = layoutEngine.layoutVariant

        retile()
    }

    // MARK: - Gap Resize

    private func adjustGap(by delta: CGFloat) {
        config.innerGap = max(0, config.innerGap + delta)
        config.outerGap = max(0, config.outerGap + delta)
        spaceyLog("Gaps: inner=\(config.innerGap) outer=\(config.outerGap)")
        retile()
    }

    // MARK: - Split Ratio

    private func adjustSplitRatio(by delta: CGFloat) {
        layoutEngine.splitRatio = max(0.2, min(0.8, layoutEngine.splitRatio + delta))
        spaceyLog("Split ratio: \(layoutEngine.splitRatio)")
        retile()
    }

    // MARK: - Focus Desktop (Empty Workspace)

    /// When no windows are on the current workspace, activate Finder so macOS
    /// doesn't keep a random app from another workspace focused.
    private func focusDesktop() {
        if let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) {
            finder.activate()
            focusedWindowID = nil
            spaceyLog("Empty workspace — focused Finder/desktop")
        }
    }

    // MARK: - Click-to-Focus Dimming Refresh

    private func setupClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            // Cancel any pending refresh
            self.clickDimWorkItem?.cancel()
            // After a mouse click, macOS activates the target window and reshuffles z-order
            // asynchronously. Wait for that to settle, then re-query focus and refresh dimming.
            let work = DispatchWorkItem { [weak self] in
                self?.refreshFocusAndDimming()
            }
            self.clickDimWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    private func refreshFocusAndDimming() {
        guard let newFocusedID = AccessibilityBridge.getFocusedWindowID(),
              trackedWindows[newFocusedID] != nil
        else { return }
        let changed = newFocusedID != focusedWindowID
        focusedWindowID = newFocusedID
        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
        if changed { onFocusChange?() }
    }

    // MARK: - Mouse Drag Resize

    private func setupResizeMonitor() {
        resizeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleResizeEvent(event)
        }
    }

    private func stopResizeMonitor() {
        if let monitor = resizeMonitor {
            NSEvent.removeMonitor(monitor)
            resizeMonitor = nil
        }
    }

    private func handleResizeEvent(_ event: NSEvent) {
        // Require Ctrl held to start a drag resize (prevents accidental triggers)
        guard layoutEngine.tiledWindows.count >= 2 else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let primaryScreen = NSScreen.screens.first else { return }
        let screenHeight = primaryScreen.frame.height
        let axPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        let region = getTilingRegion()

        switch event.type {
        case .leftMouseDown:
            // Only start resize if Ctrl is held
            guard event.modifierFlags.contains(.control) else { return }

            let isStacked = layoutEngine.layoutVariant == 1

            if isStacked {
                let splitY = region.y + region.height * layoutEngine.splitRatio
                if abs(axPoint.y - splitY) < 20 {
                    isResizing = true
                    resizeStartPos = axPoint.y
                    resizeInitialRatio = layoutEngine.splitRatio
                }
            } else {
                let splitX = region.x + region.width * layoutEngine.splitRatio
                if abs(axPoint.x - splitX) < 20 {
                    isResizing = true
                    resizeStartPos = axPoint.x
                    resizeInitialRatio = layoutEngine.splitRatio
                }
            }

        case .leftMouseDragged:
            guard isResizing else { return }
            let isStacked = layoutEngine.layoutVariant == 1

            if isStacked {
                let delta = axPoint.y - resizeStartPos
                let ratioDelta = delta / region.height
                layoutEngine.splitRatio = max(0.2, min(0.8, resizeInitialRatio + ratioDelta))
            } else {
                let delta = axPoint.x - resizeStartPos
                let ratioDelta = delta / region.width
                layoutEngine.splitRatio = max(0.2, min(0.8, resizeInitialRatio + ratioDelta))
            }

            // Snap frames instantly during drag (no animation)
            let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
                guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
                return (wid, el, t.pid)
            }
            NativeTiling.applyLayout(
                windows: windows, region: region, gap: config.innerGap,
                singleWindowPadding: config.singleWindowPadding,
                splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant,
                animate: false
            )
            let layouts = layoutEngine.calculateFrames(in: region)
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)

        case .leftMouseUp:
            if isResizing {
                isResizing = false
            }

        default:
            break
        }
    }

    // MARK: - Display Change

    @objc private func displayConfigChanged(_ notification: Notification) {
        spaceyLog("Display configuration changed, retiling")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.retile()
        }
    }

    // MARK: - Focus Follows Mouse

    private func startFocusFollowsMouse() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
        }
    }

    private func stopFocusFollowsMouse() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        // Throttle: only check every 100ms
        let now = Date()
        guard now.timeIntervalSince(lastMouseFocusTime) > 0.1 else { return }
        lastMouseFocusTime = now

        let mouseLocation = NSEvent.mouseLocation
        guard let primaryScreen = NSScreen.screens.first else { return }
        let screenHeight = primaryScreen.frame.height
        // Convert Cocoa coords to AX coords
        let axPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        // Find which tiled window contains the cursor
        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        for (windowID, frame) in layouts {
            if frame.contains(axPoint) && windowID != focusedWindowID {
                if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
                    AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    focusedWindowID = windowID
                    updateBorders(layouts: layouts)
                    updateDimming(layouts: layouts)
                }
                break
            }
        }
    }

    // MARK: - Dim Unfocused Windows (Rounded Overlay + CGSOrderWindow)

    private var dimReorderWorkItem: DispatchWorkItem?

    private func updateDimming(layouts: [(CGWindowID, CGRect)]? = nil) {
        let dimAmount = config.dimUnfocused
        guard dimAmount > 0 else { restoreAllDimming(); return }

        let focusedID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        let conn = CGSMainConnectionID()
        let tiledSet = Set(layoutEngine.tiledWindows)
        let currentLayouts = layouts ?? layoutEngine.calculateFrames(in: getTilingRegion())

        // Remove overlays for windows no longer tiled or now focused
        for wid in Array(dimmedWindows) {
            if !tiledSet.contains(wid) || wid == focusedID {
                if let overlay = dimOverlays.removeValue(forKey: wid) {
                    overlay.orderOut(nil)
                }
                dimmedWindows.remove(wid)
            }
        }

        // Create/update overlays for unfocused tiled windows
        for (wid, frame) in currentLayouts {
            if wid == focusedID {
                if let overlay = dimOverlays.removeValue(forKey: wid) {
                    overlay.orderOut(nil)
                }
                dimmedWindows.remove(wid)
                continue
            }

            let cocoaFrame = axToCocoaFrame(frame)
            if let overlay = dimOverlays[wid] {
                overlay.setFrame(cocoaFrame, display: true)
            } else {
                let overlay = makeDimOverlay(frame: cocoaFrame, alpha: dimAmount)
                dimOverlays[wid] = overlay
            }

            // Z-order: place overlay directly above target window
            if let overlay = dimOverlays[wid] {
                let overlayWid = CGWindowID(overlay.windowNumber)
                CGSOrderWindow(conn, overlayWid, 1, wid)
            }
            dimmedWindows.insert(wid)
        }

        // Schedule a delayed re-order pass. When macOS activates a window via mouse click,
        // it shuffles z-order asynchronously and can undo our CGSOrderWindow calls.
        // Re-applying after a short delay catches this.
        dimReorderWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let c = CGSMainConnectionID()
            for (wid, overlay) in self.dimOverlays {
                let oid = CGWindowID(overlay.windowNumber)
                CGSOrderWindow(c, oid, 1, wid)
            }
        }
        dimReorderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func restoreAllDimming() {
        for (_, overlay) in dimOverlays {
            overlay.orderOut(nil)
        }
        dimOverlays.removeAll()
        dimmedWindows.removeAll()
    }

    private func makeDimOverlay(frame: NSRect, alpha: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .normal
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.stationary]

        // Rounded corners matching macOS window radius
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        window.contentView = view

        window.orderFrontRegardless()
        return window
    }

    private func axToCocoaFrame(_ axFrame: CGRect) -> NSRect {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSRect(origin: .zero, size: axFrame.size)
        }
        let screenHeight = primaryScreen.frame.height
        return NSRect(
            x: axFrame.origin.x,
            y: screenHeight - axFrame.origin.y - axFrame.size.height,
            width: axFrame.size.width,
            height: axFrame.size.height
        )
    }

    // MARK: - Focus Flash Effect

    private func flashFocusedWindow() {
        guard let focusedID = focusedWindowID,
              let frame = layoutEngine.calculateFrames(in: getTilingRegion())
                  .first(where: { $0.0 == focusedID })?.1
              ?? trackedWindows[focusedID].flatMap({ _ in
                  axElements[focusedID].flatMap { AccessibilityBridge.getFrame(of: $0) }
              })
        else { return }

        flashWorkItem?.cancel()

        let cocoaFrame = axToCocoaFrame(frame)

        if flashOverlay == nil {
            let window = NSWindow(
                contentRect: cocoaFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 3)
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.stationary]

            let view = NSView(frame: NSRect(origin: .zero, size: cocoaFrame.size))
            view.wantsLayer = true
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
            view.layer?.borderWidth = 3
            view.layer?.cornerRadius = 10
            view.layer?.masksToBounds = true
            window.contentView = view
            flashOverlay = window
        } else {
            flashOverlay?.setFrame(cocoaFrame, display: false)
            flashOverlay?.contentView?.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        }

        flashOverlay?.alphaValue = 1.0
        flashOverlay?.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self?.flashOverlay?.animator().alphaValue = 0
            }, completionHandler: {
                self?.flashOverlay?.orderOut(nil)
            })
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Window Minimize to Workspace

    private func minimizeFocused() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID],
              trackedWindows[windowID] != nil
        else { return }

        if minimizedWindows.contains(windowID) {
            // Already minimized — restore it
            restoreMinimized(windowID)
            return
        }

        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)

        // Hide off-screen (same technique as workspace hiding)
        WorkspaceManager.shared.hideWindow(windowID, element: element, screenFrame: screenFrame)
        minimizedWindows.insert(windowID)

        // Remove from tiling
        let wasTiled = layoutEngine.contains(windowID)
        if wasTiled { layoutEngine.remove(windowID: windowID) }

        // Remove dim overlay
        if let overlay = dimOverlays.removeValue(forKey: windowID) {
            overlay.orderOut(nil)
        }
        dimmedWindows.remove(windowID)

        retile()

        // Focus next window or desktop
        if let firstWid = layoutEngine.tiledWindows.first,
           let el = axElements[firstWid], let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: el, pid: tracked.pid)
            focusedWindowID = firstWid
        } else {
            focusDesktop()
        }

        spaceyLog("Minimized window \(windowID)")
        onFocusChange?()
    }

    private func restoreMinimized(_ windowID: CGWindowID) {
        guard let element = axElements[windowID],
              let tracked = trackedWindows[windowID]
        else { return }

        minimizedWindows.remove(windowID)

        // Restore to visible position
        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)
        let restoreFrame = CGRect(
            x: screenFrame.origin.x + screenFrame.width / 4,
            y: screenFrame.origin.y + screenFrame.height / 4,
            width: screenFrame.width / 2,
            height: screenFrame.height / 2
        )
        AccessibilityBridge.setFrame(of: element, to: restoreFrame)

        // Re-tile if not floating
        if !floatingWindows.contains(windowID) {
            layoutEngine.insert(windowID: windowID, afterFocused: focusedWindowID)
        }

        AccessibilityBridge.focus(window: element, pid: tracked.pid)
        focusedWindowID = windowID
        retile()
        spaceyLog("Restored minimized window \(windowID)")
        onFocusChange?()
    }

    // MARK: - Scratchpad (Dedicated Ghostty Dropdown)

    /// The scratchpad launches a NEW Ghostty window (via `open -na Ghostty`)
    /// that is always floating and never interferes with existing Ghostty windows.
    private var scratchpadPendingLaunch = false

    private func toggleScratchpad() {
        if let wid = scratchpadWindowID, scratchpadVisible {
            hideScratchpad(wid)
        } else if let wid = scratchpadWindowID, !scratchpadVisible,
                  axElements[wid] != nil {
            showScratchpad(wid)
        } else {
            // Launch a brand new Ghostty instance for the scratchpad
            scratchpadPendingLaunch = true
            scratchpadWindowID = nil
            // open -na opens a new instance even if Ghostty is already running
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-na", "Ghostty"]
            task.launch()
            spaceyLog("Scratchpad: launching new Ghostty instance")
        }
    }

    /// Called from windowCreated — checks if this is the scratchpad window we're waiting for
    func checkScratchpadPending(windowID: CGWindowID, appName: String, bundleID: String?) {
        guard scratchpadPendingLaunch,
              appName == "Ghostty" || bundleID == "com.mitchellh.ghostty"
        else { return }

        scratchpadPendingLaunch = false
        scratchpadWindowID = windowID

        // Make it floating so it doesn't interfere with tiling
        floatingWindows.insert(windowID)
        if layoutEngine.contains(windowID) {
            layoutEngine.remove(windowID: windowID)
            retile()
        }

        showScratchpad(windowID)
    }

    private func showScratchpad(_ wid: CGWindowID) {
        guard let element = axElements[wid], let tracked = trackedWindows[wid] else { return }

        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)

        // Center the scratchpad at 80% width, 60% height
        let w = screenFrame.width * 0.8
        let h = screenFrame.height * 0.6
        let x = screenFrame.origin.x + (screenFrame.width - w) / 2
        let y = screenFrame.origin.y + screenFrame.height * 0.05
        let frame = CGRect(x: x, y: y, width: w, height: h)

        AccessibilityBridge.setFrame(of: element, to: frame)
        AccessibilityBridge.focus(window: element, pid: tracked.pid)
        focusedWindowID = wid
        scratchpadVisible = true

        spaceyLog("Scratchpad shown")
        onFocusChange?()
    }

    private func hideScratchpad(_ wid: CGWindowID) {
        guard let element = axElements[wid] else { return }

        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)

        WorkspaceManager.shared.hideWindow(wid, element: element, screenFrame: screenFrame)
        scratchpadVisible = false

        // Remove dim overlay if any
        if let overlay = dimOverlays.removeValue(forKey: wid) {
            overlay.orderOut(nil)
        }
        dimmedWindows.remove(wid)

        // Focus the first tiled window
        if let firstWid = layoutEngine.tiledWindows.first,
           let el = axElements[firstWid], let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: el, pid: tracked.pid)
            focusedWindowID = firstWid
        }

        spaceyLog("Scratchpad hidden")
        onFocusChange?()
    }

    // MARK: - Drag to Reorder

    private func setupDragMonitor() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDragReorder(event)
        }
    }

    private func handleDragReorder(_ event: NSEvent) {
        // Only reorder when Ctrl is held
        guard event.modifierFlags.contains(.control) else {
            dragStartWindowID = nil
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        // Convert to AX coordinates
        guard let primaryScreen = NSScreen.screens.first else { return }
        let axPoint = CGPoint(x: mouseLocation.x, y: primaryScreen.frame.height - mouseLocation.y)

        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())

        if event.type == .leftMouseDragged {
            if dragStartWindowID == nil {
                // Find which tiled window the drag started on
                for (wid, frame) in layouts {
                    if frame.contains(axPoint) {
                        dragStartWindowID = wid
                        break
                    }
                }
            }
        } else if event.type == .leftMouseUp {
            guard let startID = dragStartWindowID else { return }
            dragStartWindowID = nil

            // Find which tiled window we dropped on
            for (wid, frame) in layouts {
                if frame.contains(axPoint) && wid != startID {
                    // Swap positions in the layout engine
                    if let idx1 = layoutEngine.tiledWindows.firstIndex(of: startID),
                       let idx2 = layoutEngine.tiledWindows.firstIndex(of: wid) {
                        layoutEngine.tiledWindows.swapAt(idx1, idx2)
                        retile()
                        spaceyLog("Drag-reorder: swapped \(startID) with \(wid)")
                    }
                    break
                }
            }
        }
    }

    // MARK: - Window Marks (vim-style)

    private func setWindowMark(_ key: String) {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }
        windowMarks[key] = windowID
        let appName = trackedWindows[windowID]?.appName ?? "unknown"
        spaceyLog("Mark '\(key)' set on window \(windowID) (\(appName))")
    }

    private func jumpToWindowMark(_ key: String) {
        guard let windowID = windowMarks[key] else {
            spaceyLog("No mark '\(key)' set")
            return
        }

        // If the window is on the current workspace, just focus it
        if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = windowID
            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
            flashFocusedWindow()
            onFocusChange?()
            return
        }

        // Window might be on another workspace — find it
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        if let wsNum = WorkspaceManager.shared.findWorkspace(for: windowID, on: monitorID) {
            switchVirtualWorkspace(wsNum)
            // After switching, focus the marked window
            if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
                AccessibilityBridge.focus(window: element, pid: tracked.pid)
                focusedWindowID = windowID
                let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
                updateBorders(layouts: layouts)
                updateDimming(layouts: layouts)
                flashFocusedWindow()
                onFocusChange?()
            }
            return
        }

        // Mark is stale (window no longer exists)
        windowMarks.removeValue(forKey: key)
        spaceyLog("Mark '\(key)' was stale — window no longer exists")
    }

    // MARK: - Virtual Workspace Switching

    private func switchVirtualWorkspace(_ number: Int) {
        guard number >= 1 && number <= 9 else { return }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)

        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        guard number != currentWS else {
            spaceyLog("Already on workspace \(number)")
            return
        }

        // Pause observer to prevent race conditions during workspace switch
        observer.pause()
        defer { observer.resume() }

        let screenFrame = screenFrameInAX(for: screen)

        // Remove dim overlays before switching (they reference old workspace windows)
        restoreAllDimming()

        // Save current layout variant for this workspace
        workspaceLayouts["\(monitorID)-\(currentWS)"] = layoutEngine.layoutVariant

        // Save current state into WorkspaceManager
        saveWorkspaceState(workspace: currentWS, monitor: monitorID)

        // Switch: hides old windows (moves off-screen), activates new workspace number
        // Sticky windows are excluded from hiding — they stay visible on all workspaces
        WorkspaceManager.shared.switchWorkspace(to: number, on: monitorID, screenFrame: screenFrame, stickyWindows: stickyWindows)

        // Load new workspace state
        loadWorkspaceState(workspace: number, monitor: monitorID)

        // Restore layout variant for this workspace
        if let savedVariant = workspaceLayouts["\(monitorID)-\(number)"] {
            layoutEngine.layoutVariant = savedVariant
        }

        retile()

        // Restore floating/fullscreen windows to their saved positions
        // (retile only handles tiled windows; floating windows need explicit restoration)
        restoreFloatingWindowPositions()

        // If workspace is empty, focus Finder so macOS doesn't keep a
        // random app from another workspace focused
        if layoutEngine.tiledWindows.isEmpty && floatingWindows.isEmpty {
            focusDesktop()
        } else if let firstWid = layoutEngine.tiledWindows.first,
                  let element = axElements[firstWid],
                  let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = firstWid
        }

        onSpaceChange?()
        spaceyLog("Switched to workspace \(number) on \(monitorID)")
    }

    private func moveToVirtualWorkspace(_ number: Int) {
        guard number >= 1 && number <= 9 else { return }
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        // Sticky windows cannot be moved to a specific workspace (they're on all)
        guard !stickyWindows.contains(windowID) else {
            spaceyLog("Cannot move sticky window to workspace — it's visible on all workspaces")
            return
        }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1

        guard number != currentWS else {
            spaceyLog("Window already on workspace \(number)")
            return
        }

        // Remove from current WM state
        let wasTiled = layoutEngine.contains(windowID)
        if wasTiled { layoutEngine.remove(windowID: windowID) }

        let tracked = trackedWindows.removeValue(forKey: windowID)
        let element = axElements.removeValue(forKey: windowID)
        let wasFloating = floatingWindows.remove(windowID) != nil
        let wasFullscreen = fullscreenWindows.remove(windowID) != nil
        dimmedWindows.remove(windowID)
        if let overlay = dimOverlays.removeValue(forKey: windowID) {
            overlay.orderOut(nil)
        }

        // Hide the window (move off-screen)
        let screenFrame = screenFrameInAX(for: screen)
        WorkspaceManager.shared.hideWindow(windowID, element: element, screenFrame: screenFrame)

        // Add to target workspace in WorkspaceManager
        var targetWS = WorkspaceManager.shared.workspaces[monitorID]?[number] ?? VirtualWorkspace()
        if let tracked = tracked {
            targetWS.trackedWindows[windowID] = tracked
        }
        if let element = element {
            targetWS.axElements[windowID] = element
        }
        if wasFloating {
            targetWS.floatingWindows.insert(windowID)
        } else if wasFullscreen {
            targetWS.fullscreenWindows.insert(windowID)
        } else if wasTiled {
            targetWS.tiledWindows.append(windowID)
        }
        WorkspaceManager.shared.workspaces[monitorID, default: [:]][number] = targetWS

        // Focus next window on current workspace
        if focusedWindowID == windowID {
            focusedWindowID = layoutEngine.tiledWindows.first
            if let fid = focusedWindowID, let el = axElements[fid], let t = trackedWindows[fid] {
                AccessibilityBridge.focus(window: el, pid: t.pid)
            }
        }

        retile()
        onSpaceChange?()
        spaceyLog("Moved window \(windowID) to workspace \(number)")
    }

    private func saveWorkspaceState(workspace: Int, monitor: String) {
        // Snapshot current floating window positions before saving
        for wid in floatingWindows {
            if let element = axElements[wid], let frame = AccessibilityBridge.getFrame(of: element) {
                trackedWindows[wid]?.frame = frame
            }
        }
        // Also snapshot fullscreen window positions
        for wid in fullscreenWindows {
            if let element = axElements[wid], let frame = AccessibilityBridge.getFrame(of: element) {
                trackedWindows[wid]?.frame = frame
            }
        }

        var ws = VirtualWorkspace()
        ws.tiledWindows = layoutEngine.tiledWindows
        ws.floatingWindows = floatingWindows
        ws.fullscreenWindows = fullscreenWindows
        ws.trackedWindows = trackedWindows
        ws.axElements = axElements
        ws.focusedWindowID = focusedWindowID
        ws.layoutVariant = layoutEngine.layoutVariant
        ws.splitRatio = layoutEngine.splitRatio
        WorkspaceManager.shared.workspaces[monitor, default: [:]][workspace] = ws

        // Persist to disk (debounced)
        WorkspacePersistence.save()
    }

    /// Restore floating and fullscreen windows to their saved positions after workspace switch.
    /// Tiled windows are handled by retile(); this handles non-tiled windows.
    private func restoreFloatingWindowPositions() {
        for wid in floatingWindows {
            guard let element = axElements[wid],
                  let tracked = trackedWindows[wid],
                  tracked.frame != .zero else { continue }
            AccessibilityBridge.setFrame(of: element, to: tracked.frame)
        }
        for wid in fullscreenWindows {
            guard let element = axElements[wid],
                  let tracked = trackedWindows[wid],
                  tracked.frame != .zero else { continue }
            AccessibilityBridge.setFrame(of: element, to: tracked.frame)
        }
    }

    private func loadWorkspaceState(workspace: Int, monitor: String) {
        // Include ALL windows (active + hidden) in knownWindows so the observer
        // doesn't re-discover hidden windows as "new" on every poll cycle
        let hiddenIDs = WorkspaceManager.shared.allHiddenWindowIDs()

        // Preserve sticky windows from the previous workspace so they carry forward
        let previousStickyTracked = trackedWindows.filter { stickyWindows.contains($0.key) }
        let previousStickyElements = axElements.filter { stickyWindows.contains($0.key) }
        let previousStickyFloating = floatingWindows.intersection(stickyWindows)
        let previousStickyTiled = layoutEngine.tiledWindows.filter { stickyWindows.contains($0) }

        if let ws = WorkspaceManager.shared.workspaces[monitor]?[workspace] {
            layoutEngine.tiledWindows = ws.tiledWindows
            trackedWindows = ws.trackedWindows
            axElements = ws.axElements
            floatingWindows = ws.floatingWindows
            fullscreenWindows = ws.fullscreenWindows
            focusedWindowID = ws.focusedWindowID ?? ws.tiledWindows.first
            layoutEngine.layoutVariant = ws.layoutVariant
            layoutEngine.splitRatio = ws.splitRatio
            var allKnown = Set(ws.trackedWindows.keys)
            allKnown.formUnion(hiddenIDs)
            observer.syncKnownWindows(allKnown)
        } else {
            // Empty workspace — clear everything
            layoutEngine.tiledWindows.removeAll()
            trackedWindows.removeAll()
            axElements.removeAll()
            floatingWindows.removeAll()
            fullscreenWindows.removeAll()
            focusedWindowID = nil
            observer.syncKnownWindows(hiddenIDs)
        }

        // Merge sticky windows into the new workspace state
        for (wid, tracked) in previousStickyTracked {
            trackedWindows[wid] = tracked
        }
        for (wid, element) in previousStickyElements {
            axElements[wid] = element
        }
        floatingWindows.formUnion(previousStickyFloating)
        for wid in previousStickyTiled {
            if !layoutEngine.tiledWindows.contains(wid) {
                layoutEngine.insert(windowID: wid, afterFocused: nil)
            }
        }

        // Ensure sticky windows are included in known windows
        var currentKnown = observer.currentKnownWindows
        currentKnown.formUnion(stickyWindows)
        observer.syncKnownWindows(currentKnown)

        // Focus the workspace's focused window
        if let fid = focusedWindowID, let el = axElements[fid], let t = trackedWindows[fid] {
            AccessibilityBridge.focus(window: el, pid: t.pid)
        }
    }

    // MARK: - Force ProMotion 120Hz

    private var proMotionWindow: NSWindow?
    private var proMotionTimer: DispatchSourceTimer?

    private func startDisplayLink() {
        guard proMotionWindow == nil else { return }

        // Create a tiny 1x1 transparent window that continuously redraws,
        // forcing macOS ProMotion to stay at its max refresh rate (120Hz).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.alphaValue = 0.01  // Nearly invisible but still composited
        window.collectionBehavior = [.stationary, .canJoinAllSpaces]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        proMotionWindow = window

        // Redraw the view at ~120fps to keep ProMotion active
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))  // ~120fps
        timer.setEventHandler { [weak view] in
            view?.layer?.setNeedsDisplay()
        }
        timer.resume()
        proMotionTimer = timer

        spaceyLog("ProMotion force enabled (120Hz keepalive)")
    }

    private func stopDisplayLink() {
        proMotionTimer?.cancel()
        proMotionTimer = nil
        proMotionWindow?.orderOut(nil)
        proMotionWindow = nil
        spaceyLog("ProMotion force disabled")
    }

    // MARK: - Crash Recovery

    /// On launch, check for windows stuck at hidden positions (from a previous crash)
    /// and move them back on-screen.
    private func restoreOrphanedWindows() {
        let allWindows = SpaceManager.getWindowsOnCurrentSpace()
        for screen in NSScreen.screens {
            let screenFrame = screenFrameInAX(for: screen)
            for wid in allWindows {
                guard let info = SpaceManager.getWindowInfo(wid) else { continue }
                if WorkspaceManager.shared.isHiddenPosition(screenFrame: screenFrame, windowFrame: info.frame) {
                    if let (element, _) = AccessibilityBridge.getWindows(for: info.pid).first(where: { $0.1 == wid }) {
                        let centerX = screenFrame.origin.x + screenFrame.width / 4
                        let centerY = screenFrame.origin.y + screenFrame.height / 4
                        let restoredFrame = CGRect(x: centerX, y: centerY, width: info.frame.width, height: info.frame.height)
                        AccessibilityBridge.setFrame(of: element, to: restoredFrame)
                        spaceyLog("Restored orphaned window \(wid) (\(info.appName)) from hidden position")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Convert NSScreen frame to AX/Core Graphics coordinates (origin top-left of primary display)
    func screenFrameInAX(for screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axY = primaryHeight - screen.frame.origin.y - screen.frame.height
        return CGRect(x: screen.frame.origin.x, y: axY, width: screen.frame.width, height: screen.frame.height)
    }

    func appMatchesRule(_ appName: String, bundleID: String?, rules: Set<String>) -> Bool {
        if rules.contains(appName) { return true }
        if let bid = bundleID, rules.contains(bid) { return true }
        let lowered = appName.lowercased()
        return rules.contains { $0.lowercased() == lowered }
    }

}
