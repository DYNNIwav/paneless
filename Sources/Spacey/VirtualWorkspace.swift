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
        // Fallback: use frame description
        return "display-\(screen.frame.origin.x)-\(screen.frame.origin.y)"
    }

    /// Switch workspace: hide old windows, activate new workspace, show windows
    func switchWorkspace(to number: Int, on monitorID: String) {
        let oldNumber = activeWorkspace[monitorID] ?? 1
        let conn = CGSMainConnectionID()

        // Hide windows on old workspace (move off-screen + alpha 0)
        if let oldWS = workspaces[monitorID]?[oldNumber] {
            let allWindows = Array(oldWS.trackedWindows.keys)
            for wid in allWindows {
                if let element = oldWS.axElements[wid] {
                    AccessibilityBridge.setFrame(of: element, to: CGRect(x: 10000, y: 10000, width: 1, height: 1))
                }
                CGSSetWindowAlpha(conn, wid, 0)
            }
        }

        // Activate new workspace
        activeWorkspace[monitorID] = number

        // Show windows on new workspace (restore alpha — positions restored by retile)
        if let newWS = workspaces[monitorID]?[number] {
            let allWindows = Array(newWS.trackedWindows.keys)
            for wid in allWindows {
                CGSSetWindowAlpha(conn, wid, 1.0)
            }
        }
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
}
