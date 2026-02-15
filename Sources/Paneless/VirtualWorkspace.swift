import Cocoa

struct VirtualWorkspace {
    var tiledWindows: [CGWindowID] = []
    var floatingWindows: Set<CGWindowID> = []
    var fullscreenWindows: Set<CGWindowID> = []
    var trackedWindows: [CGWindowID: TrackedWindow] = [:]
    var axElements: [CGWindowID: AXUIElement] = [:]
    var focusedWindowID: CGWindowID?
    var layoutVariant: Int = 0
    var splitRatio: CGFloat = 0.5

    // Niri mode state
    var niriActiveColumn: Int = 0
    var niriColumns: [NiriColumn] = []
}

class WorkspaceManager {
    static let shared = WorkspaceManager()

    /// Per-monitor workspaces: screenID -> (workspace number -> state)
    var workspaces: [String: [Int: VirtualWorkspace]] = [:]

    /// Active workspace number per monitor
    var activeWorkspace: [String: Int] = [:]

    private init() {}

    /// Stable monitor identifier based on display ID
    func screenID(for screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return "display-\(screenNumber)"
        }
        return "display-\(screen.frame.origin.x)-\(screen.frame.origin.y)"
    }

    /// Calculate hidden position for a window (rift-style: bottom-right corner, 1px visible).
    /// Keeps original size so macOS doesn't clamp to minimum.
    func calculateHiddenPosition(screenFrame: CGRect, originalSize: CGSize) -> CGRect {
        // Position at bottom-right corner with 1px visible
        let hiddenX = screenFrame.maxX - 1.0
        let hiddenY = screenFrame.maxY - 1.0
        return CGRect(x: hiddenX, y: hiddenY, width: originalSize.width, height: originalSize.height)
    }

    /// Check if a window is at a hidden position
    func isHiddenPosition(screenFrame: CGRect, windowFrame: CGRect) -> Bool {
        // Calculate visible area within screen bounds
        let visibleWidth = max(0, min(windowFrame.maxX, screenFrame.maxX) - max(windowFrame.origin.x, screenFrame.origin.x))
        let visibleHeight = max(0, min(windowFrame.maxY, screenFrame.maxY) - max(windowFrame.origin.y, screenFrame.origin.y))
        return visibleWidth <= 3.0 || visibleHeight <= 3.0
    }

    /// Hide a single window by moving to screen corner (1px visible)
    func hideWindow(_ wid: CGWindowID, element: AXUIElement?, screenFrame: CGRect) {
        guard let element = element else { return }
        let currentFrame = AccessibilityBridge.getFrame(of: element)
        let size = currentFrame?.size ?? CGSize(width: 800, height: 600)
        let hiddenPos = calculateHiddenPosition(screenFrame: screenFrame, originalSize: size)
        AccessibilityBridge.setFrame(of: element, to: hiddenPos)
    }

    /// Switch workspace: hide old windows, activate new workspace, show new windows.
    /// Uses SLSDisableUpdate/SLSReenableUpdate to batch all moves atomically.
    /// Sticky windows are excluded from hiding — they remain visible across all workspaces.
    func switchWorkspace(to number: Int, on monitorID: String, screenFrame: CGRect, stickyWindows: Set<CGWindowID> = []) {
        let oldNumber = activeWorkspace[monitorID] ?? 1
        let conn = CGSMainConnectionID()

        // Batch all window moves — no redraws until SLSReenableUpdate
        SLSDisableUpdate(conn)

        // Hide windows on old workspace (skip sticky windows)
        if let oldWS = workspaces[monitorID]?[oldNumber] {
            for wid in oldWS.trackedWindows.keys {
                guard !stickyWindows.contains(wid) else { continue }
                hideWindow(wid, element: oldWS.axElements[wid], screenFrame: screenFrame)
            }
        }

        // Activate new workspace
        activeWorkspace[monitorID] = number

        // New workspace windows will be positioned by retile() after this call
        // (retile calls NativeTiling.applyLayout which moves windows to correct positions)

        SLSReenableUpdate(conn)
    }

    /// Get workspace numbers that have windows on a given monitor
    func workspacesWithWindows(on monitorID: String) -> [Int] {
        guard let monitorWS = workspaces[monitorID] else { return [] }
        return monitorWS.filter { !$0.value.trackedWindows.isEmpty }.map { $0.key }.sorted()
    }

    /// Get the window count for a workspace
    func windowCount(workspace: Int, on monitorID: String) -> Int {
        return workspaces[monitorID]?[workspace]?.trackedWindows.count ?? 0
    }

    /// All window IDs that are hidden on non-active workspaces
    func allHiddenWindowIDs() -> Set<CGWindowID> {
        var hidden = Set<CGWindowID>()
        for (monitorID, monitorWorkspaces) in workspaces {
            let active = activeWorkspace[monitorID] ?? 1
            for (wsNum, ws) in monitorWorkspaces where wsNum != active {
                hidden.formUnion(ws.trackedWindows.keys)
            }
        }
        return hidden
    }

    /// Check if a specific window is on a non-active workspace
    func isWindowHiddenOnOtherWorkspace(_ windowID: CGWindowID) -> Bool {
        for (monitorID, monitorWorkspaces) in workspaces {
            let active = activeWorkspace[monitorID] ?? 1
            for (wsNum, ws) in monitorWorkspaces where wsNum != active {
                if ws.trackedWindows[windowID] != nil { return true }
            }
        }
        return false
    }

    /// Find which workspace a window is on (for Cmd+Tab integration)
    func findWorkspace(for windowID: CGWindowID, on monitorID: String) -> Int? {
        guard let monitorWorkspaces = workspaces[monitorID] else { return nil }
        for (wsNum, ws) in monitorWorkspaces {
            if ws.trackedWindows[windowID] != nil { return wsNum }
        }
        return nil
    }
}
