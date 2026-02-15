import Cocoa

/// Persists workspace window assignments to disk so they can be restored after a reboot or crash.
/// Saves to ~/.config/paneless/workspaces.json
enum WorkspacePersistence {

    private static let savePath: String = {
        let dir = NSString("~/.config/paneless").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("workspaces.json")
    }()

    /// Debounce: track last save time to avoid writing too frequently
    private static var lastSaveTime: Date = .distantPast
    private static let minSaveInterval: TimeInterval = 5.0
    private static var pendingSave: DispatchWorkItem?

    // MARK: - Data Structures

    struct SavedWindow: Codable {
        let appName: String
        let bundleID: String?
        let windowTitle: String?
        let workspace: Int
        let monitor: String
        let isFloating: Bool
        let isFullscreen: Bool
    }

    struct SavedState: Codable {
        let windows: [SavedWindow]
        let activeWorkspaces: [String: Int]
        let timestamp: Date
    }

    // MARK: - Save

    /// Save current workspace assignments. Debounced to max once per 5 seconds.
    static func save(debounced: Bool = true) {
        if debounced {
            let now = Date()
            if now.timeIntervalSince(lastSaveTime) < minSaveInterval {
                // Schedule a delayed save if one isn't already pending
                if pendingSave == nil {
                    let work = DispatchWorkItem { save(debounced: false) }
                    pendingSave = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + minSaveInterval, execute: work)
                }
                return
            }
        }

        pendingSave?.cancel()
        pendingSave = nil
        lastSaveTime = Date()

        let wsMgr = WorkspaceManager.shared
        let wm = WindowManager.shared
        var savedWindows: [SavedWindow] = []

        // Save the currently active workspace's windows from WindowManager
        for (monitorID, monitorWorkspaces) in wsMgr.workspaces {
            let activeWS = wsMgr.activeWorkspace[monitorID] ?? 1

            for (wsNum, ws) in monitorWorkspaces {
                for (wid, tracked) in ws.trackedWindows {
                    // For the active workspace, get the live window title
                    var title: String?
                    if wsNum == activeWS, let element = wm.axElements[wid] {
                        title = AccessibilityBridge.getTitle(of: element)
                    } else if let element = ws.axElements[wid] {
                        title = AccessibilityBridge.getTitle(of: element)
                    }

                    savedWindows.append(SavedWindow(
                        appName: tracked.appName,
                        bundleID: tracked.bundleID,
                        windowTitle: title,
                        workspace: wsNum,
                        monitor: monitorID,
                        isFloating: ws.floatingWindows.contains(wid),
                        isFullscreen: ws.fullscreenWindows.contains(wid)
                    ))
                }
            }
        }

        let state = SavedState(
            windows: savedWindows,
            activeWorkspaces: wsMgr.activeWorkspace,
            timestamp: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(state)
            try data.write(to: URL(fileURLWithPath: savePath))
            panelessLog("Workspace state saved (\(savedWindows.count) windows)")
        } catch {
            panelessLog("Failed to save workspace state: \(error)")
        }
    }

    /// Immediate save (for quit/terminate)
    static func saveImmediate() {
        save(debounced: false)
    }

    // MARK: - Load

    /// Load saved workspace assignments from disk.
    static func load() -> SavedState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: savePath)) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(SavedState.self, from: data)

            // Ignore stale state (older than 24 hours — windows are long gone)
            if Date().timeIntervalSince(state.timestamp) > 86400 {
                panelessLog("Ignoring stale workspace state (>24h old)")
                return nil
            }

            return state
        } catch {
            panelessLog("Failed to load workspace state: \(error)")
            return nil
        }
    }

    // MARK: - Restore

    /// After startup scan, try to reassign windows to their saved workspaces.
    /// Matches by app name + bundle ID + window title.
    static func restoreWorkspaceAssignments() {
        guard let savedState = load() else { return }

        let wm = WindowManager.shared
        let wsMgr = WorkspaceManager.shared

        let screen = NSScreen.safeMain
        let monitorID = wsMgr.screenID(for: screen)
        let screenFrame = wm.screenFrameInAX(for: screen)

        var movedCount = 0

        for saved in savedState.windows {
            // Only restore to non-active workspaces (active workspace windows are already scanned)
            let activeWS = wsMgr.activeWorkspace[monitorID] ?? 1
            guard saved.workspace != activeWS else { continue }

            // Find a matching window in the current tiled/tracked set
            let matchedWID = findMatchingWindow(saved: saved, in: wm)
            guard let windowID = matchedWID else { continue }

            // Remove from current workspace state
            let wasTiled = wm.layoutEngine.contains(windowID)
            if wasTiled { wm.layoutEngine.remove(windowID: windowID) }
            let tracked = wm.trackedWindows.removeValue(forKey: windowID)
            let element = wm.axElements.removeValue(forKey: windowID)
            let wasFloating = wm.floatingWindows.remove(windowID) != nil
            let wasFullscreen = wm.fullscreenWindows.remove(windowID) != nil

            // Hide the window
            wsMgr.hideWindow(windowID, element: element, screenFrame: screenFrame)

            // Add to saved workspace
            var targetWS = wsMgr.workspaces[monitorID]?[saved.workspace] ?? VirtualWorkspace()
            if let tracked = tracked {
                targetWS.trackedWindows[windowID] = tracked
            }
            if let element = element {
                targetWS.axElements[windowID] = element
            }
            if saved.isFloating || wasFloating {
                targetWS.floatingWindows.insert(windowID)
            } else if saved.isFullscreen || wasFullscreen {
                targetWS.fullscreenWindows.insert(windowID)
            } else {
                targetWS.tiledWindows.append(windowID)
            }
            wsMgr.workspaces[monitorID, default: [:]][saved.workspace] = targetWS

            movedCount += 1
        }

        if movedCount > 0 {
            // Update observer's known windows to include newly hidden windows
            let hiddenIDs = wsMgr.allHiddenWindowIDs()
            let allWindows = Set(SpaceManager.getWindowsOnCurrentSpace())
            var allKnown = allWindows
            allKnown.formUnion(hiddenIDs)
            wm.observer.syncKnownWindows(allKnown)

            wm.retile()
            panelessLog("Restored \(movedCount) windows to their saved workspaces")
        }
    }

    private static func findMatchingWindow(saved: SavedWindow, in wm: WindowManager) -> CGWindowID? {
        var bestMatch: (wid: CGWindowID, score: Double) = (0, -1)

        for (wid, tracked) in wm.trackedWindows {
            let appMatch = tracked.appName == saved.appName
                || (tracked.bundleID != nil && tracked.bundleID == saved.bundleID)
            guard appMatch else { continue }

            // Exact title match — best possible
            if let element = wm.axElements[wid],
               let title = AccessibilityBridge.getTitle(of: element),
               title == saved.windowTitle {
                return wid
            }

            // Fuzzy title match via Jaccard word similarity
            if let savedTitle = saved.windowTitle,
               let element = wm.axElements[wid],
               let title = AccessibilityBridge.getTitle(of: element) {
                let similarity = jaccardSimilarity(title, savedTitle)
                if similarity > bestMatch.score {
                    bestMatch = (wid, similarity)
                }
            } else if bestMatch.score < 0 {
                // No title to compare — app-only match as fallback
                bestMatch = (wid, 0)
            }
        }

        // Accept fuzzy matches with any word overlap (score > 0),
        // or fall back to app-only match (score == 0)
        if bestMatch.score >= 0 {
            return bestMatch.wid
        }

        return nil
    }

    /// Jaccard similarity on word sets: |intersection| / |union|.
    /// Returns 0.0 for no overlap, 1.0 for identical word sets.
    private static func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }
}
