import Cocoa

class WindowManager: WindowObserverDelegate {
    static let shared = WindowManager()

    var config: PanelessConfig
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
    private var dimmedWindows: Set<CGWindowID> = []  // windows currently at reduced brightness
    private var clickMonitor: Any?
    private var clickDimWorkItem: DispatchWorkItem?
    private var resizeMonitor: Any?
    private var isResizing = false
    private var resizeStartPos: CGFloat = 0
    private var resizeInitialRatio: CGFloat = 0.5

    // Minimized windows (hidden but tracked in workspace)
    private var minimizedWindows: Set<CGWindowID> = []

    // Window marks (vim-style: key -> windowID)
    private var windowMarks: [String: CGWindowID] = [:]

    // Per-workspace layout memory
    private var workspaceLayouts: [String: Int] = [:]  // "monitorID-wsNum" -> layoutVariant

    // Drag-to-reorder
    private var dragMonitor: Any?
    private var dragStartWindowID: CGWindowID?

    // Niri mode: windows hidden because they're off-screen in the scrolling strip
    private var niriHiddenWindows: Set<CGWindowID> = []
    private var niriHideWorkItem: DispatchWorkItem?

    // Window swallowing: child GUI window ID -> swallowed parent (terminal) window ID
    private var swallowedWindows: [CGWindowID: CGWindowID] = [:]

    // Focus-follows-app: guard against re-entrant workspace switches
    private var isAutoSwitching = false

    private init() {
        self.config = PanelessConfig.load()
        self.layoutEngine = LayoutEngine(config: config)
        self.observer = WindowObserver()
        self.eventTap = EventTap()
    }

    func start() {
        BorderManager.shared.config = config.border
        eventTap.keyBindings = config.keyBindings
        eventTap.hyperkeyCode = config.hyperkeyCode
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

        // Reset any stale alpha/brightness from previous crash or failed dimming attempts
        restoreAllDimming()

        // Reset any stale CGS transforms from a previous crash mid-animation
        let allWindowIDs = SpaceManager.getWindowsOnCurrentSpace()
        Animator.shared.resetTransforms(for: allWindowIDs)

        // Initialize virtual workspace 1 with the scanned windows
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        WorkspaceManager.shared.activeWorkspace[monitorID] = 1
        saveWorkspaceState(workspace: 1, monitor: monitorID)
        panelessLog("Initialized workspace 1 on \(monitorID) with \(layoutEngine.tiledWindows.count) tiled windows")

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

        panelessLog("Paneless started (monitors: \(NSScreen.screens.count), bindings: \(config.keyBindings.count))")
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
        panelessLog("Paneless stopped")
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
        case .setMark(let key):             setWindowMark(key)
        case .jumpToMark(let key):          jumpToWindowMark(key)
        case .niriConsume:                  niriConsume()
        case .niriExpel:                    niriExpel()
        }
    }

    // MARK: - Focus Navigation

    private func focusInDirection(_ direction: Direction) {
        if config.niriMode {
            // In Niri mode, left/right scrolls columns, up/down navigates within column
            switch direction {
            case .left:  niriFocusDirection(-1)
            case .right: niriFocusDirection(1)
            case .up:    niriFocusVertical(-1)
            case .down:  niriFocusVertical(1)
            }
            return
        }

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
            onFocusChange?()
        }
    }

    /// Cycle focus through tiled AND floating windows in list order (wraps around).
    private func focusCycle(forward: Bool) {
        if config.niriMode {
            niriFocusDirection(forward ? 1 : -1)
            return
        }

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
        if config.niriMode {
            // Move active column to first position
            let colIdx = layoutEngine.niriActiveColumn
            guard colIdx > 0 && colIdx < layoutEngine.niriColumns.count else { return }
            let col = layoutEngine.niriColumns.remove(at: colIdx)
            layoutEngine.niriColumns.insert(col, at: 0)
            layoutEngine.niriActiveColumn = 0
            layoutEngine.syncTiledWindowsFromColumns()
            retile()
            return
        }
        layoutEngine.swapWithFirst(currentID)
        retile()
    }

    private func rotateWindows(forward: Bool) {
        guard layoutEngine.tiledWindows.count >= 2 else { return }

        if config.niriMode {
            // In Niri mode, J/K navigates up/down within the active column
            niriFocusVertical(forward ? 1 : -1)
            return
        }

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
            // Use the full visible screen (menu bar + dock respected, no Paneless gaps)
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
        let oldMode = config.tilingMode
        config = PanelessConfig.load()
        layoutEngine.config = config

        // Reset Niri state if mode changed
        if config.tilingMode != oldMode {
            // Unhide any Niri-hidden windows before clearing
            let conn = CGSMainConnectionID()
            for wid in niriHiddenWindows {
                CGSSetWindowAlpha(conn, wid, 1.0)
            }
            niriHiddenWindows.removeAll()
            layoutEngine.niriActiveColumn = 0
            layoutEngine.niriColumns.removeAll()
        }
        BorderManager.shared.config = config.border
        eventTap.keyBindings = config.keyBindings
        eventTap.hyperkeyCode = config.hyperkeyCode

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
        panelessLog("Config reloaded")
    }

    // MARK: - Tiling

    func retile() {
        if config.niriMode {
            retileNiri()
            return
        }

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
                panelessLog("retile: menu tiling failed, falling back to AX frames")
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
        if config.niriMode {
            retileNiriWithScaleIn(newWindowID: newWindowID)
            return
        }

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
                let scale: CGFloat = 0.80
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

        // In Niri mode, rebuild columns from the flat tiled window list
        if config.niriMode {
            layoutEngine.rebuildColumnsFromTiledWindows()
        }

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

        // Auto-float dialogs and small windows
        if !shouldFloat, config.autoFloatDialogs, let element = axElements[windowID] {
            if AccessibilityBridge.isDialog(element) || AccessibilityBridge.isSmallWindow(element) {
                shouldFloat = true
                panelessLog("Auto-floating dialog/small window: \(appName) (\(windowID))")
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
                    panelessLog("Auto-floating secondary window from \(appName) (\(windowID))")
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

                panelessLog("Auto-moved \(appName) (\(windowID)) to workspace \(target)")
                return
            }
        }

        // Window swallowing: check if this new window's process is a child of a tiled terminal
        if !shouldFloat, axElements[windowID] != nil,
           let terminalWID = findSwallowableParent(childPID: pid) {
            // Record swallow relationship
            swallowedWindows[windowID] = terminalWID
            trackedWindows[windowID]?.swallowedFrom = terminalWID
            trackedWindows[terminalWID]?.swallowedBy = windowID

            // Find terminal's position in layout
            let terminalIndex = layoutEngine.tiledWindows.firstIndex(of: terminalWID)

            // Hide the terminal window
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, terminalWID, 0.0)
            let screen = NSScreen.safeMain
            let screenFrame = screenFrameInAX(for: screen)
            if let termElement = axElements[terminalWID] {
                WorkspaceManager.shared.hideWindow(terminalWID, element: termElement, screenFrame: screenFrame)
            }

            // Remove terminal from tiling (but keep in trackedWindows)
            if config.niriMode {
                layoutEngine.removeWindowFromColumns(terminalWID)
            }
            layoutEngine.remove(windowID: terminalWID)

            // Insert new window at the terminal's old position
            if let idx = terminalIndex {
                layoutEngine.tiledWindows.insert(windowID, at: min(idx, layoutEngine.tiledWindows.count))
            } else {
                layoutEngine.insert(windowID: windowID, afterFocused: focusedWindowID)
            }

            if config.niriMode {
                layoutEngine.insertWindowAsNewColumn(windowID)
                if let ci = layoutEngine.niriColumns.firstIndex(where: { $0.windows.contains(windowID) }) {
                    layoutEngine.niriActiveColumn = ci
                }
            }

            focusedWindowID = windowID
            CGSSetWindowAlpha(conn, windowID, 0.0)
            retileWithScaleIn(newWindowID: windowID)

            panelessLog("Swallowed \(trackedWindows[terminalWID]?.appName ?? "terminal") (\(terminalWID)) → \(appName) (\(windowID))")
            return
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

            // In Niri mode, insert as new column and scroll to it
            if config.niriMode {
                layoutEngine.insertWindowAsNewColumn(windowID)
                if let idx = layoutEngine.niriColumns.firstIndex(where: { $0.windows.contains(windowID) }) {
                    layoutEngine.niriActiveColumn = idx
                }
            }

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

        // Clean up minimized state
        minimizedWindows.remove(windowID)
        niriHiddenWindows.remove(windowID)

        // Clean up any marks pointing to this window
        windowMarks = windowMarks.filter { $0.value != windowID }

        let destroyedPid = trackedWindows[windowID]?.pid

        // Window swallowing: if this window swallowed a terminal, restore it
        if let terminalWID = swallowedWindows.removeValue(forKey: windowID),
           trackedWindows[terminalWID] != nil {
            // Find the destroyed window's position in the layout
            let destroyedIndex = layoutEngine.tiledWindows.firstIndex(of: windowID)

            // Remove the GUI window from layout first
            if config.niriMode {
                layoutEngine.removeWindowFromColumns(windowID)
            }
            layoutEngine.remove(windowID: windowID)

            // Clean up the destroyed window
            trackedWindows.removeValue(forKey: windowID)
            axElements.removeValue(forKey: windowID)
            floatingWindows.remove(windowID)
            fullscreenWindows.remove(windowID)
            stickyWindows.remove(windowID)

            // Restore the terminal window
            trackedWindows[terminalWID]?.swallowedBy = nil

            // Unhide the terminal
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, terminalWID, 1.0)

            // Re-insert terminal into layout at the GUI window's old position
            if let idx = destroyedIndex {
                layoutEngine.tiledWindows.insert(terminalWID, at: min(idx, layoutEngine.tiledWindows.count))
            } else {
                layoutEngine.tiledWindows.append(terminalWID)
            }

            if config.niriMode {
                layoutEngine.insertWindowAsNewColumn(terminalWID)
                if let ci = layoutEngine.niriColumns.firstIndex(where: { $0.windows.contains(terminalWID) }) {
                    layoutEngine.niriActiveColumn = ci
                }
            }

            // Focus the restored terminal
            if let element = axElements[terminalWID], let tracked = trackedWindows[terminalWID] {
                AccessibilityBridge.focus(window: element, pid: tracked.pid)
                focusedWindowID = terminalWID
            }

            retile()
            panelessLog("Unswallowed terminal (\(terminalWID)), restored to layout")

            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
            return
        }

        // If this window WAS a swallowed terminal (but the child outlived it), clean up
        if let swallowedBy = trackedWindows[windowID]?.swallowedBy {
            swallowedWindows.removeValue(forKey: swallowedBy)
            trackedWindows[swallowedBy]?.swallowedFrom = nil
        }

        trackedWindows.removeValue(forKey: windowID)
        axElements.removeValue(forKey: windowID)
        floatingWindows.remove(windowID)
        fullscreenWindows.remove(windowID)
        stickyWindows.remove(windowID)
        if dimmedWindows.remove(windowID) != nil {
            var wids: [CGWindowID] = [windowID]
            var values: [Float] = [0.0]
            CGSSetWindowListBrightness(CGSMainConnectionID(), &wids, &values, 1)
        }

        // Remove from Niri columns (handles active column adjustment and tiledWindows sync)
        if config.niriMode {
            layoutEngine.removeWindowFromColumns(windowID)
        }

        let wasTiled = layoutEngine.contains(windowID)
        if wasTiled {
            layoutEngine.remove(windowID: windowID)
            // In Niri mode, tiledWindows was already synced by removeWindowFromColumns
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
                    // No windows left on this workspace — focus Finder/desktop.
                    // Suppress focus-follows-app so activating Finder doesn't
                    // pull us to another workspace.
                    isAutoSwitching = true
                    focusDesktop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.isAutoSwitching = false
                    }
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
        panelessLog("Native space change detected (ignored — using virtual workspaces)")
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

        // Update column's focusedIndex when external focus changes
        if config.niriMode {
            if let (ci, ri) = layoutEngine.findWindowInColumns(newFocusedID) {
                layoutEngine.niriColumns[ci].focusedIndex = ri
                layoutEngine.niriActiveColumn = ci
            }
        }

        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)

        onFocusChange?()
    }

    func applicationLaunched(pid: pid_t, name: String) {}

    func applicationActivated(pid: pid_t, name: String) {
        guard config.focusFollowsApp, !isAutoSwitching else { return }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1

        // Check if the activated app has windows on the current workspace
        let hasWindowOnCurrent = trackedWindows.values.contains { $0.pid == pid }
        if hasWindowOnCurrent { return }

        // Don't follow app activation away from an empty workspace.
        // This happens when closing the last window — macOS activates the
        // next app in Z-order, which may have windows on another workspace.
        // The user should stay on their current workspace.
        if layoutEngine.tiledWindows.isEmpty && floatingWindows.isEmpty {
            panelessLog("Focus-follows-app: suppressed on empty workspace (closed last window)")
            return
        }

        // Search other workspaces for windows belonging to this app's PID
        guard let monitorWorkspaces = WorkspaceManager.shared.workspaces[monitorID] else { return }
        for (wsNum, ws) in monitorWorkspaces where wsNum != currentWS {
            if ws.trackedWindows.values.contains(where: { $0.pid == pid }) {
                panelessLog("Focus-follows-app: \(name) (pid \(pid)) on workspace \(wsNum), switching")
                isAutoSwitching = true
                switchVirtualWorkspace(wsNum)
                isAutoSwitching = false
                return
            }
        }
    }

    func applicationTerminated(pid: pid_t, name: String) {
        let toRemove = trackedWindows.filter { $0.value.pid == pid }.map { $0.key }
        for windowID in toRemove {
            windowDestroyed(windowID: windowID)
        }
    }

    // MARK: - Cycle Layout

    private func cycleLayout() {
        if config.niriMode {
            // Cycle column width presets: 1.0 → 0.5 → 0.333
            let presets: [CGFloat] = [1.0, 0.5, 1.0/3.0]
            let current = config.niriColumnWidth
            // Find the next preset after the current width
            let nextIdx = presets.firstIndex(where: { abs($0 - current) < 0.01 }).map { ($0 + 1) % presets.count } ?? 0
            config.niriColumnWidth = presets[nextIdx]
            // Clear per-column overrides so the new default takes effect
            for i in layoutEngine.niriColumns.indices {
                layoutEngine.niriColumns[i].widthOverride = nil
            }
            let names = ["full", "half", "third"]
            panelessLog("Niri column width: \(names[nextIdx])")
            retile()
            return
        }

        layoutEngine.cycleVariant()
        let names = ["side-by-side", "stacked", "monocle"]
        panelessLog("Layout: \(names[layoutEngine.layoutVariant])")

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
        panelessLog("Gaps: inner=\(config.innerGap) outer=\(config.outerGap)")
        retile()
    }

    // MARK: - Split Ratio

    private func adjustSplitRatio(by delta: CGFloat) {
        if config.niriMode {
            // Adjust active column's width override
            guard !layoutEngine.niriColumns.isEmpty else { return }
            let idx = max(0, min(layoutEngine.niriActiveColumn, layoutEngine.niriColumns.count - 1))
            let current = layoutEngine.niriColumns[idx].widthOverride ?? config.niriColumnWidth
            layoutEngine.niriColumns[idx].widthOverride = max(0.1, min(3.0, current + delta))
            panelessLog("Niri column \(idx) width: \(layoutEngine.niriColumns[idx].widthOverride!)")
            retile()
            return
        }

        layoutEngine.splitRatio = max(0.2, min(0.8, layoutEngine.splitRatio + delta))
        panelessLog("Split ratio: \(layoutEngine.splitRatio)")
        retile()
    }

    // MARK: - Niri Scrolling Column Mode

    /// Core Niri retile: calculate column frames, animate visible windows, hide off-screen ones.
    private func retileNiri() {
        let region = getTilingRegion()
        let results = NativeTiling.calculateNiriFrames(
            columns: layoutEngine.niriColumns,
            region: region,
            gap: config.innerGap,
            activeColumn: layoutEngine.niriActiveColumn,
            defaultColumnWidth: config.niriColumnWidth
        )

        // Position off-screen windows at their strip locations (keeps positions correct for scroll animation)
        for colResult in results where !colResult.isVisible {
            for (wid, frame) in colResult.windowFrames {
                guard let element = axElements[wid] else { continue }
                AccessibilityBridge.setFrame(of: element, to: frame)
            }
        }

        niriUpdateVisibility(results)

        // Animate visible windows
        var transitions: [Animator.Transition] = []
        for colResult in results where colResult.isVisible {
            for (wid, frame) in colResult.windowFrames {
                guard let element = axElements[wid],
                      let _ = trackedWindows[wid]
                else { continue }
                let currentFrame = AccessibilityBridge.getFrame(of: element) ?? frame
                transitions.append(Animator.Transition(
                    windowID: wid,
                    element: element,
                    startFrame: currentFrame,
                    targetFrame: frame
                ))
            }
        }

        if !transitions.isEmpty {
            Animator.shared.animate(transitions)
        }

        let visibleLayouts: [(CGWindowID, CGRect)] = results.filter { $0.isVisible }.flatMap { $0.windowFrames.map { ($0.windowID, $0.frame) } }
        updateBorders(layouts: visibleLayouts)
        updateDimming(layouts: visibleLayouts)
    }

    /// Niri retile with scale-in animation for a new window.
    private func retileNiriWithScaleIn(newWindowID: CGWindowID) {
        let region = getTilingRegion()
        let results = NativeTiling.calculateNiriFrames(
            columns: layoutEngine.niriColumns,
            region: region,
            gap: config.innerGap,
            activeColumn: layoutEngine.niriActiveColumn,
            defaultColumnWidth: config.niriColumnWidth
        )

        niriUpdateVisibility(results)

        var transitions: [Animator.Transition] = []
        for colResult in results where colResult.isVisible {
            for (wid, frame) in colResult.windowFrames {
                guard let element = axElements[wid] else { continue }

                let startFrame: CGRect
                let isNew: Bool
                if wid == newWindowID {
                    let scale: CGFloat = 0.80
                    startFrame = CGRect(
                        x: frame.midX - frame.width * scale / 2,
                        y: frame.midY - frame.height * scale / 2,
                        width: frame.width * scale,
                        height: frame.height * scale
                    )
                    isNew = true
                } else {
                    startFrame = AccessibilityBridge.getFrame(of: element) ?? frame
                    isNew = false
                }

                transitions.append(Animator.Transition(
                    windowID: wid,
                    element: element,
                    startFrame: startFrame,
                    targetFrame: frame,
                    isNewWindow: isNew
                ))
            }
        }

        if !transitions.isEmpty {
            Animator.shared.animate(transitions)
        }

        let visibleLayouts: [(CGWindowID, CGRect)] = results.filter { $0.isVisible }.flatMap { $0.windowFrames.map { ($0.windowID, $0.frame) } }
        updateBorders(layouts: visibleLayouts)
        updateDimming(layouts: visibleLayouts)
    }

    /// Scroll to an adjacent column (delta: -1 for left, +1 for right).
    private func niriFocusDirection(_ delta: Int) {
        guard !layoutEngine.niriColumns.isEmpty else { return }
        let newCol = layoutEngine.niriActiveColumn + delta
        guard newCol >= 0 && newCol < layoutEngine.niriColumns.count else { return }
        niriScrollToColumn(newCol)
    }

    /// Animate scroll from current column to target column.
    /// Windows stay at strip positions (alpha-hidden), so animation is a smooth slide.
    private func niriScrollToColumn(_ col: Int) {
        guard col >= 0 && col < layoutEngine.niriColumns.count else { return }

        let region = getTilingRegion()
        let conn = CGSMainConnectionID()

        // Cancel any pending hide from a previous scroll
        niriHideWorkItem?.cancel()

        // Update active column
        layoutEngine.niriActiveColumn = col

        // Calculate target positions
        let results = NativeTiling.calculateNiriFrames(
            columns: layoutEngine.niriColumns,
            region: region,
            gap: config.innerGap,
            activeColumn: col,
            defaultColumnWidth: config.niriColumnWidth
        )

        // Atomically restore alpha for windows about to become visible
        // (they're already at their strip positions thanks to alpha-only hiding)
        SLSDisableUpdate(conn)
        for colResult in results where colResult.isVisible {
            for (wid, _) in colResult.windowFrames {
                if niriHiddenWindows.remove(wid) != nil {
                    CGSSetWindowAlpha(conn, wid, 1.0)
                }
            }
        }
        SLSReenableUpdate(conn)

        // Build transitions for visible + departing windows
        var transitions: [Animator.Transition] = []
        for colResult in results {
            for (wid, targetFrame) in colResult.windowFrames {
                guard let element = axElements[wid], let _ = trackedWindows[wid] else { continue }
                // Animate windows that are currently visible or will become visible
                let isCurrentlyVisible = !niriHiddenWindows.contains(wid)
                guard colResult.isVisible || isCurrentlyVisible else { continue }
                let currentFrame = AccessibilityBridge.getFrame(of: element) ?? targetFrame
                transitions.append(Animator.Transition(
                    windowID: wid, element: element,
                    startFrame: currentFrame, targetFrame: targetFrame
                ))
            }
        }

        if !transitions.isEmpty {
            Animator.shared.animate(transitions)
        }

        // After animation, hide off-screen windows + position at strip locations
        let hideWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let hConn = CGSMainConnectionID()
            for colResult in results where !colResult.isVisible {
                for (wid, frame) in colResult.windowFrames {
                    if !self.niriHiddenWindows.contains(wid) {
                        self.niriHiddenWindows.insert(wid)
                        CGSSetWindowAlpha(hConn, wid, 0.0)
                    }
                    if let element = self.axElements[wid] {
                        AccessibilityBridge.setFrame(of: element, to: frame)
                    }
                }
            }
            var known = self.observer.currentKnownWindows
            known.formUnion(self.niriHiddenWindows)
            self.observer.syncKnownWindows(known)
        }
        niriHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: hideWork)

        // Focus the target window
        if let targetWID = layoutEngine.niriColumns[col].focusedWindow,
           let element = axElements[targetWID], let tracked = trackedWindows[targetWID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = targetWID
        }

        let visibleLayouts = results.filter { $0.isVisible }.flatMap { $0.windowFrames.map { ($0.windowID, $0.frame) } }
        updateBorders(layouts: visibleLayouts)
        updateDimming(layouts: visibleLayouts)
        onFocusChange?()
    }

    /// Hide off-screen windows and unhide on-screen ones for Niri mode.
    /// Uses alpha-only hiding so windows stay at their strip positions for smooth animation.
    private func niriUpdateVisibility(_ results: [NativeTiling.NiriColumnResult]) {
        let conn = CGSMainConnectionID()

        for colResult in results {
            for (wid, _) in colResult.windowFrames {
                if colResult.isVisible {
                    if niriHiddenWindows.remove(wid) != nil {
                        CGSSetWindowAlpha(conn, wid, 1.0)
                    }
                } else {
                    if !niriHiddenWindows.contains(wid) {
                        niriHiddenWindows.insert(wid)
                        CGSSetWindowAlpha(conn, wid, 0.0)
                    }
                }
            }
        }

        // Sync observer's known windows to include niri-hidden windows
        var known = observer.currentKnownWindows
        known.formUnion(niriHiddenWindows)
        observer.syncKnownWindows(known)
    }

    /// Navigate up/down within the active column's window stack.
    private func niriFocusVertical(_ delta: Int) {
        guard !layoutEngine.niriColumns.isEmpty else { return }
        let ci = max(0, min(layoutEngine.niriActiveColumn, layoutEngine.niriColumns.count - 1))
        let col = layoutEngine.niriColumns[ci]
        guard col.windows.count > 1 else { return }

        let newRow = col.clampedFocusedIndex + delta
        guard newRow >= 0 && newRow < col.windows.count else { return }

        layoutEngine.niriColumns[ci].focusedIndex = newRow
        let targetWID = col.windows[newRow]

        if let element = axElements[targetWID], let tracked = trackedWindows[targetWID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = targetWID
        }

        retileNiri()

        onFocusChange?()
    }

    /// Consume: take the first window from the right column and append to the current column.
    private func niriConsume() {
        guard config.niriMode else { return }
        let ci = layoutEngine.niriActiveColumn
        guard ci >= 0 && ci < layoutEngine.niriColumns.count else { return }
        let rightIdx = ci + 1
        guard rightIdx < layoutEngine.niriColumns.count else { return }

        // Take the first window from the right column
        let wid = layoutEngine.niriColumns[rightIdx].windows.removeFirst()

        // If right column is now empty, remove it
        if layoutEngine.niriColumns[rightIdx].windows.isEmpty {
            layoutEngine.niriColumns.remove(at: rightIdx)
        } else {
            layoutEngine.niriColumns[rightIdx].focusedIndex = 0
        }

        // Append to current column
        layoutEngine.niriColumns[ci].windows.append(wid)
        layoutEngine.niriColumns[ci].focusedIndex = layoutEngine.niriColumns[ci].windows.count - 1

        // Unhide the consumed window if it was off-screen
        if niriHiddenWindows.remove(wid) != nil {
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, wid, 1.0)
        }

        layoutEngine.syncTiledWindowsFromColumns()
        focusedWindowID = wid
        retileNiri()

        onFocusChange?()
        panelessLog("Niri consume: absorbed window \(wid) into column \(ci)")
    }

    /// Expel: eject focused window from a multi-window column into its own column to the right.
    private func niriExpel() {
        guard config.niriMode else { return }
        let ci = layoutEngine.niriActiveColumn
        guard ci >= 0 && ci < layoutEngine.niriColumns.count else { return }
        guard layoutEngine.niriColumns[ci].windows.count > 1 else { return }

        let ri = layoutEngine.niriColumns[ci].clampedFocusedIndex
        let wid = layoutEngine.niriColumns[ci].windows.remove(at: ri)

        // Clamp focusedIndex after removal
        layoutEngine.niriColumns[ci].focusedIndex = min(ri, layoutEngine.niriColumns[ci].windows.count - 1)

        // Insert as new column to the right
        let newCol = NiriColumn(windows: [wid], widthOverride: layoutEngine.niriColumns[ci].widthOverride)
        layoutEngine.niriColumns.insert(newCol, at: ci + 1)

        // Move focus to the new column
        layoutEngine.niriActiveColumn = ci + 1

        layoutEngine.syncTiledWindowsFromColumns()
        focusedWindowID = wid
        retileNiri()

        onFocusChange?()
        panelessLog("Niri expel: ejected window \(wid) into new column \(ci + 1)")
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
            panelessLog("Empty workspace — focused Finder/desktop")
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
        panelessLog("Display configuration changed, retiling")
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

    // MARK: - Dim Unfocused Windows (Compositor Brightness)

    /// Uses CGSSetWindowListBrightness as an additive brightness offset:
    ///   0.0 = normal, negative = darker, positive = brighter.
    /// Compositor-level — follows window shape, rounded corners, shadow perfectly.

    private func updateDimming(layouts: [(CGWindowID, CGRect)]? = nil) {
        let dimAmount = config.dimUnfocused
        guard dimAmount > 0 else { restoreAllDimming(); return }

        let focusedID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        let conn = CGSMainConnectionID()
        let tiledSet = Set(layoutEngine.tiledWindows)
        let offset = -Float(dimAmount)  // e.g. dim=0.3 → offset=-0.3 (darker)

        // Restore windows no longer tiled or now focused
        var toRestore: [CGWindowID] = []
        for wid in Array(dimmedWindows) {
            if !tiledSet.contains(wid) || wid == focusedID {
                toRestore.append(wid)
                dimmedWindows.remove(wid)
            }
        }
        if !toRestore.isEmpty {
            var wids = toRestore
            var values = [Float](repeating: 0.0, count: toRestore.count)
            CGSSetWindowListBrightness(conn, &wids, &values, Int32(toRestore.count))
        }

        // Dim unfocused tiled windows
        var toDim: [CGWindowID] = []
        for wid in layoutEngine.tiledWindows {
            if wid == focusedID {
                if dimmedWindows.contains(wid) {
                    var wids: [CGWindowID] = [wid]
                    var values: [Float] = [0.0]
                    CGSSetWindowListBrightness(conn, &wids, &values, 1)
                    dimmedWindows.remove(wid)
                }
                continue
            }
            toDim.append(wid)
            dimmedWindows.insert(wid)
        }

        if !toDim.isEmpty {
            var wids = toDim
            var values = [Float](repeating: offset, count: toDim.count)
            CGSSetWindowListBrightness(conn, &wids, &values, Int32(toDim.count))
        }
    }

    private func restoreAllDimming() {
        let conn = CGSMainConnectionID()
        // Reset brightness offset to 0.0 (normal) for all visible windows
        let allWindowIDs = SpaceManager.getWindowsOnCurrentSpace()
        if !allWindowIDs.isEmpty {
            var wids = allWindowIDs
            var values = [Float](repeating: 0.0, count: allWindowIDs.count)
            CGSSetWindowListBrightness(conn, &wids, &values, Int32(allWindowIDs.count))
        }
        dimmedWindows.removeAll()
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

        if dimmedWindows.remove(windowID) != nil {
            var wids: [CGWindowID] = [windowID]
            var values: [Float] = [0.0]
            CGSSetWindowListBrightness(CGSMainConnectionID(), &wids, &values, 1)
        }

        retile()

        // Focus next window or desktop
        if let firstWid = layoutEngine.tiledWindows.first,
           let el = axElements[firstWid], let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: el, pid: tracked.pid)
            focusedWindowID = firstWid
        } else {
            focusDesktop()
        }

        panelessLog("Minimized window \(windowID)")
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
        panelessLog("Restored minimized window \(windowID)")
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
                        panelessLog("Drag-reorder: swapped \(startID) with \(wid)")
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
        panelessLog("Mark '\(key)' set on window \(windowID) (\(appName))")
    }

    private func jumpToWindowMark(_ key: String) {
        guard let windowID = windowMarks[key] else {
            panelessLog("No mark '\(key)' set")
            return
        }

        // If the window is on the current workspace, just focus it
        if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = windowID
            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)

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
    
                onFocusChange?()
            }
            return
        }

        // Mark is stale (window no longer exists)
        windowMarks.removeValue(forKey: key)
        panelessLog("Mark '\(key)' was stale — window no longer exists")
    }

    // MARK: - Virtual Workspace Switching

    private func switchVirtualWorkspace(_ number: Int) {
        guard number >= 1 && number <= 9 else { return }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)

        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        guard number != currentWS else {
            panelessLog("Already on workspace \(number)")
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
        } else if let fid = focusedWindowID,
                  let element = axElements[fid],
                  let tracked = trackedWindows[fid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
        } else if let firstWid = layoutEngine.tiledWindows.first,
                  let element = axElements[firstWid],
                  let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = firstWid
        }

        onSpaceChange?()
        panelessLog("Switched to workspace \(number) on \(monitorID)")
    }

    private func moveToVirtualWorkspace(_ number: Int) {
        guard number >= 1 && number <= 9 else { return }
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        // Sticky windows cannot be moved to a specific workspace (they're on all)
        guard !stickyWindows.contains(windowID) else {
            panelessLog("Cannot move sticky window to workspace — it's visible on all workspaces")
            return
        }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1

        guard number != currentWS else {
            panelessLog("Window already on workspace \(number)")
            return
        }

        // Remove from current WM state
        let wasTiled = layoutEngine.contains(windowID)
        if wasTiled { layoutEngine.remove(windowID: windowID) }

        let tracked = trackedWindows.removeValue(forKey: windowID)
        let element = axElements.removeValue(forKey: windowID)
        let wasFloating = floatingWindows.remove(windowID) != nil
        let wasFullscreen = fullscreenWindows.remove(windowID) != nil
        if dimmedWindows.remove(windowID) != nil {
            var wids: [CGWindowID] = [windowID]
            var values: [Float] = [0.0]
            CGSSetWindowListBrightness(CGSMainConnectionID(), &wids, &values, 1)
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
        panelessLog("Moved window \(windowID) to workspace \(number)")
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
        ws.niriActiveColumn = layoutEngine.niriActiveColumn
        ws.niriColumns = layoutEngine.niriColumns
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
            layoutEngine.niriActiveColumn = ws.niriActiveColumn
            layoutEngine.niriColumns = ws.niriColumns
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

        panelessLog("ProMotion force enabled (120Hz keepalive)")
    }

    private func stopDisplayLink() {
        proMotionTimer?.cancel()
        proMotionTimer = nil
        proMotionWindow?.orderOut(nil)
        proMotionWindow = nil
        panelessLog("ProMotion force disabled")
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
                        panelessLog("Restored orphaned window \(wid) (\(info.appName)) from hidden position")
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

    // MARK: - Window Swallowing Helpers

    /// Get the parent PID of a process using proc_pidinfo.
    private func getParentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return nil }
        let ppid = pid_t(info.pbi_ppid)
        return ppid > 1 ? ppid : nil
    }

    /// Walk the PID chain upward to find a parent that owns a swallowable terminal window.
    /// Returns the terminal's window ID if found.
    private func findSwallowableParent(childPID: pid_t) -> CGWindowID? {
        var currentPID = childPID
        // Walk up to 5 levels (child → shell → terminal)
        for _ in 0..<5 {
            guard let parentPID = getParentPID(currentPID) else { return nil }

            // Check if any tiled window belongs to this parent PID and is a swallowable app
            for wid in layoutEngine.tiledWindows {
                guard let tracked = trackedWindows[wid],
                      tracked.pid == parentPID,
                      tracked.swallowedBy == nil  // not already swallowed
                else { continue }

                if config.swallowAll ||
                   appMatchesRule(tracked.appName, bundleID: tracked.bundleID, rules: config.swallowApps) {
                    return wid
                }
            }

            currentPID = parentPID
        }
        return nil
    }

}
