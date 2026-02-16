import Cocoa

enum AccessibilityBridge {

    /// Get the focused window's AXUIElement, CGWindowID, and owner PID
    static func getFocusedWindow() -> (AXUIElement, CGWindowID, pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowElement = focusedWindow else { return nil }

        var windowID: CGWindowID = 0
        let err = _AXUIElementGetWindow(windowElement as! AXUIElement, &windowID)
        guard err == .success, windowID != 0 else { return nil }

        return (windowElement as! AXUIElement, windowID, app.processIdentifier)
    }

    static func getFocusedWindowID() -> CGWindowID? {
        return getFocusedWindow()?.1
    }

    // MARK: - Frame Operations

    static func getFrame(of element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    static func setFrame(of element: AXUIElement, to rect: CGRect) {
        // Disable AXEnhancedUserInterface to prevent app-side animations.
        // Same workaround used by Amethyst/Silica and yabai.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appRef = pid != 0 ? AXUIElementCreateApplication(pid) : nil

        var wasEnhanced = false
        if let appRef = appRef {
            var enhancedValue: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &enhancedValue) == .success {
                wasEnhanced = (enhancedValue as? Bool) ?? false
            }
            if wasEnhanced {
                AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        // Set size -> position -> size to handle apps that constrain position based on size
        var size = rect.size
        var position = rect.origin

        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }

        // Restore AXEnhancedUserInterface
        if wasEnhanced, let appRef = appRef {
            AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Batch set frames for multiple windows. Disables AXEnhancedUserInterface once per app
    /// instead of once per window, reducing IPC overhead significantly.
    static func batchSetFrames(_ frames: [(element: AXUIElement, frame: CGRect)]) {
        guard !frames.isEmpty else { return }

        // Phase 1: Disable AXEnhancedUserInterface for all unique apps
        var pidApps: [pid_t: (appRef: AXUIElement, wasEnhanced: Bool)] = [:]

        for (element, _) in frames {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard pid != 0, pidApps[pid] == nil else { continue }

            let appRef = AXUIElementCreateApplication(pid)
            var enhancedValue: AnyObject?
            var wasEnhanced = false
            if AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &enhancedValue) == .success {
                wasEnhanced = (enhancedValue as? Bool) ?? false
            }
            if wasEnhanced {
                AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            pidApps[pid] = (appRef, wasEnhanced)
        }

        // Phase 2: Set all frames (size -> position -> size for each)
        for (element, rect) in frames {
            var size = rect.size
            var position = rect.origin

            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            }
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
        }

        // Phase 3: Restore AXEnhancedUserInterface for apps that had it
        for (_, (appRef, wasEnhanced)) in pidApps where wasEnhanced {
            AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - Window Enumeration

    static func getWindows(for pid: pid_t) -> [(AXUIElement, CGWindowID)] {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return [] }

        var result: [(AXUIElement, CGWindowID)] = []
        for window in windows {
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 {
                result.append((window, windowID))
            }
        }
        return result
    }

    // MARK: - Window Actions

    static func focus(window element: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    /// Focus a window using only AX attributes — no app activation of any kind.
    /// Safe to call during space transitions. Both NSRunningApplication.activate()
    /// and kAXFrontmostAttribute cause macOS to switch spaces when apps have
    /// windows on multiple spaces.
    static func focusLocally(window element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func close(window element: AXUIElement) {
        var closeButton: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success
        else { return }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        var minimized: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
        return (minimized as? Bool) ?? false
    }

    static func getTitle(of element: AXUIElement) -> String? {
        var title: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    /// Check if a window is a dialog, sheet, or utility panel that should auto-float.
    static func isDialog(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleStr = subrole as? String {
            let dialogRoles: Set<String> = [
                "AXDialog", "AXSheet", "AXFloatingWindow",
                "AXSystemDialog", "AXSystemFloatingWindow"
            ]
            if dialogRoles.contains(subroleStr) {
                return true
            }
        }
        return false
    }

    /// Check if a window is small enough to be considered a popup/dialog.
    /// Threshold: below 500x400 is likely a dialog or utility.
    static func isSmallWindow(_ element: AXUIElement, threshold: CGSize = CGSize(width: 500, height: 400)) -> Bool {
        guard let frame = getFrame(of: element) else { return false }
        return frame.width < threshold.width && frame.height < threshold.height
    }

    // MARK: - Menu Item Traversal

    /// Find a menu item by traversing the AX menu bar hierarchy.
    /// Path example: ["Window", "Move & Resize", "Left Half"]
    /// Returns the AXUIElement of the menu item if found.
    static func findMenuItem(pid: pid_t, path: [String]) -> AXUIElement? {
        guard !path.isEmpty else { return nil }

        let app = AXUIElementCreateApplication(pid)

        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBarElement = menuBar
        else { return nil }

        var current: AXUIElement = menuBarElement as! AXUIElement

        for (depth, name) in path.enumerated() {
            var children: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
                  let items = children as? [AXUIElement]
            else { return nil }

            var found: AXUIElement?
            for item in items {
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title) == .success,
                   let titleStr = title as? String, titleStr == name {
                    found = item
                    break
                }
            }

            guard let matchedItem = found else { return nil }

            // If this is not the last path component, descend into its submenu
            if depth < path.count - 1 {
                // Menu bar items and menu items with submenus have children that are the submenu
                var submenuChildren: AnyObject?
                if AXUIElementCopyAttributeValue(matchedItem, kAXChildrenAttribute as CFString, &submenuChildren) == .success,
                   let submenus = submenuChildren as? [AXUIElement], let submenu = submenus.first {
                    current = submenu
                } else {
                    return nil
                }
            } else {
                return matchedItem
            }
        }

        return nil
    }

    /// Press a menu item found by path. Returns true if the action was performed.
    @discardableResult
    static func pressMenuItem(pid: pid_t, path: [String]) -> Bool {
        guard let menuItem = findMenuItem(pid: pid, path: path) else { return false }
        return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
    }

    // MARK: - Window Tiling via Menu Items

    /// Find the Window menu for an app. Tries English "Window" first, then
    /// scans all top-level menus for one containing a "Fill" or "Move & Resize" child item
    /// (handles localized menus like Norwegian "Vindu", German "Fenster", etc.).
    private static func findWindowMenu(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success
        else { return nil }

        let menuBarElement = menuBar as! AXUIElement

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &children) == .success,
              let topItems = children as? [AXUIElement]
        else { return nil }

        // First pass: try known Window menu names
        let knownNames: Set<String> = ["Window", "Vindu", "Fenster", "Fenêtre", "Ventana", "Finestra", "Janela", "Fönster", "Ikkuna", "Vindue"]
        for item in topItems {
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title) == .success,
               let name = title as? String, knownNames.contains(name) {
                return item
            }
        }

        // Second pass: find a menu that contains "Fill" or "Move & Resize" as direct children
        // (these are macOS-injected items present in all apps on Sequoia+)
        for item in topItems {
            var subChildren: AnyObject?
            guard AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subChildren) == .success,
                  let subMenus = subChildren as? [AXUIElement], let subMenu = subMenus.first
            else { continue }

            var menuItems: AnyObject?
            guard AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
                  let items = menuItems as? [AXUIElement]
            else { continue }

            for menuItem in items {
                var itemTitle: AnyObject?
                if AXUIElementCopyAttributeValue(menuItem, kAXTitleAttribute as CFString, &itemTitle) == .success,
                   let name = itemTitle as? String {
                    if name == "Fill" || name == "Minimize" || name == "Move & Resize" {
                        return item
                    }
                }
            }
        }

        return nil
    }

    /// Find a child menu item by title within a menu's submenu.
    private static func findChildItem(in menuBarItem: AXUIElement, title: String) -> AXUIElement? {
        var subChildren: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &subChildren) == .success,
              let subMenus = subChildren as? [AXUIElement], let subMenu = subMenus.first
        else { return nil }

        var menuItems: AnyObject?
        guard AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
              let items = menuItems as? [AXUIElement]
        else { return nil }

        for item in items {
            var itemTitle: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle) == .success,
               let name = itemTitle as? String, name == title {
                return item
            }
        }
        return nil
    }

    /// Find a submenu item within a parent menu item (e.g., "Left" inside "Move & Resize").
    private static func findSubmenuItem(in parentItem: AXUIElement, title: String) -> AXUIElement? {
        var subChildren: AnyObject?
        guard AXUIElementCopyAttributeValue(parentItem, kAXChildrenAttribute as CFString, &subChildren) == .success,
              let subMenus = subChildren as? [AXUIElement], let subMenu = subMenus.first
        else { return nil }

        var menuItems: AnyObject?
        guard AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
              let items = menuItems as? [AXUIElement]
        else { return nil }

        for item in items {
            var itemTitle: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle) == .success,
               let name = itemTitle as? String, name == title {
                return item
            }
        }
        return nil
    }

    /// Press a Window tiling menu item. Handles the two structures:
    /// - Direct items: Fill, Center (Window > Fill)
    /// - Submenu items: Left, Right, etc. (Window > Move & Resize > Left)
    @discardableResult
    static func pressWindowTileItem(pid: pid_t, action: NativeTiling.NativeTileAction) -> Bool {
        guard let windowMenu = findWindowMenu(pid: pid) else {
            panelessLog("pressWindowTileItem: no Window menu for pid \(pid)")
            return false
        }

        let menuItem: AXUIElement?

        switch action {
        case .fill:
            menuItem = findChildItem(in: windowMenu, title: "Fill")
        case .center:
            menuItem = findChildItem(in: windowMenu, title: "Center")
        default:
            let submenuTitle: String
            switch action {
            case .left:        submenuTitle = "Left"
            case .right:       submenuTitle = "Right"
            case .top:         submenuTitle = "Top"
            case .bottom:      submenuTitle = "Bottom"
            case .topLeft:     submenuTitle = "Top Left"
            case .topRight:    submenuTitle = "Top Right"
            case .bottomLeft:  submenuTitle = "Bottom Left"
            case .bottomRight: submenuTitle = "Bottom Right"
            default:           return false
            }

            guard let moveResize = findChildItem(in: windowMenu, title: "Move & Resize") else {
                panelessLog("pressWindowTileItem: 'Move & Resize' not found for pid \(pid)")
                return false
            }
            menuItem = findSubmenuItem(in: moveResize, title: submenuTitle)
        }

        guard let item = menuItem else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

}
