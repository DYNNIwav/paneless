import Cocoa

/// Layout application using AX frame setting with smooth animation.
/// Calculates simple layouts (fill, halves, quarters) and uses the Animator
/// for smooth frame interpolation via the compositor.
enum NativeTiling {

    // Layout variants
    static let variantCount = 3
    // 0 = side-by-side (default)
    // 1 = stacked (top/bottom)
    // 2 = monocle (all fill, overlapping)

    // MARK: - Native Menu-Based Tiling (macOS Sequoia+)

    /// macOS tiling actions available under the Window menu (Sequoia+).
    /// These trigger native compositor-driven animation (GPU texture movement,
    /// zero content redraw) — the smoothest possible window animation on macOS.
    ///
    /// Menu structure (from AX dump):
    ///   Window > Fill                          (direct child)
    ///   Window > Center                        (direct child)
    ///   Window > Move & Resize > Left          (submenu)
    ///   Window > Move & Resize > Right         (submenu)
    ///   Window > Move & Resize > Top Left      (submenu)
    ///   ...etc
    enum NativeTileAction {
        case fill          // Window > Fill (direct)
        case center        // Window > Center (direct)
        case left          // Window > Move & Resize > Left
        case right         // Window > Move & Resize > Right
        case top           // Window > Move & Resize > Top
        case bottom        // Window > Move & Resize > Bottom
        case topLeft       // Window > Move & Resize > Top Left
        case topRight      // Window > Move & Resize > Top Right
        case bottomLeft    // Window > Move & Resize > Bottom Left
        case bottomRight   // Window > Move & Resize > Bottom Right
    }

    /// Whether menu-based tiling can be used for the given layout.
    /// Requires: standard split ratio (0.5), variant 0 (side-by-side) or 1 (stacked),
    /// window count 1-4, and not monocle mode.
    static func canUseMenuTiling(count: Int, splitRatio: CGFloat, variant: Int) -> Bool {
        guard count >= 1 && count <= 4 else { return false }
        guard abs(splitRatio - 0.5) < 0.01 else { return false }
        guard variant == 0 || variant == 1 else { return false }
        return true
    }

    /// Tile a single window via the macOS Window menu items.
    /// The window's owning app must be focused for the menu item to apply to it.
    /// Returns true if the menu item was found and pressed.
    @discardableResult
    static func tileViaMenu(pid: pid_t, action: NativeTileAction) -> Bool {
        return AccessibilityBridge.pressWindowTileItem(pid: pid, action: action)
    }

    /// Determine the native tile actions for a given layout configuration.
    /// Returns nil if the layout cannot be expressed with native tiling.
    static func menuActionsForLayout(count: Int, variant: Int) -> [NativeTileAction]? {
        switch (count, variant) {
        case (1, _):
            return [.fill]
        case (2, 0): // side-by-side
            return [.left, .right]
        case (2, 1): // stacked
            return [.top, .bottom]
        case (3, 0): // left half + two right quarters
            return [.left, .topRight, .bottomRight]
        case (3, 1): // three rows — no native equivalent for 1/3 splits
            return nil
        case (4, 0): // four quarters
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case (4, 1): // four rows — no native equivalent
            return nil
        default:
            return nil
        }
    }

    /// Apply layout using native macOS menu tiling for compositor-driven animation.
    /// Each window is focused then tiled via the menu item, producing smooth native animation.
    /// Returns true if all windows were tiled successfully, false if any failed (caller should fall back).
    @discardableResult
    static func applyViaMenu(
        windows: [(windowID: CGWindowID, element: AXUIElement, pid: pid_t)],
        variant: Int
    ) -> Bool {
        guard let actions = menuActionsForLayout(count: windows.count, variant: variant) else {
            return false
        }

        guard windows.count == actions.count else { return false }

        var allSucceeded = true

        for (i, window) in windows.enumerated() {
            // Focus the window so the menu item applies to it
            AccessibilityBridge.focus(window: window.element, pid: window.pid)

            // Brief pause to let focus take effect before pressing the menu item.
            // Without this, the menu item may apply to the previously focused window.
            usleep(50_000) // 50ms

            if !tileViaMenu(pid: window.pid, action: actions[i]) {
                allSucceeded = false
            }
        }

        return allSucceeded
    }

    // MARK: - Frame Calculation

    /// Calculate layout frames for 1-4 windows.
    /// - Parameters:
    ///   - singleWindowPadding: Extra padding when only 1 window is tiled (0 = fill)
    ///   - splitRatio: Ratio of first window to remaining (0.2-0.8, default 0.5)
    ///   - variant: Layout variant (0=side-by-side, 1=stacked, 2=monocle)
    static func calculateFrames(count: Int, region: TilingRegion, gap: CGFloat,
                                singleWindowPadding: CGFloat = 0,
                                splitRatio: CGFloat = 0.5,
                                variant: Int = 0) -> [CGRect] {
        let halfGap = gap / 2

        guard count > 0 else { return [] }

        // Monocle: all windows get the same fill frame
        if variant == 2 {
            let frame = CGRect(
                x: region.x + halfGap,
                y: region.y + halfGap,
                width: max(region.width - gap, 100),
                height: max(region.height - gap, 100)
            )
            return Array(repeating: frame, count: count)
        }

        switch count {
        case 1:
            let pad = singleWindowPadding
            if pad == 0 {
                // No padding: remove all gaps for true fullscreen feel
                return [CGRect(
                    x: region.x,
                    y: region.y,
                    width: max(region.width, 100),
                    height: max(region.height, 100)
                )]
            }
            return [CGRect(
                x: region.x + halfGap + pad,
                y: region.y + halfGap + pad,
                width: max(region.width - gap - pad * 2, 100),
                height: max(region.height - gap - pad * 2, 100)
            )]

        case 2:
            if variant == 1 {
                // Stacked: top/bottom
                let topH = region.height * splitRatio
                let botH = region.height * (1.0 - splitRatio)
                return [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(region.width - gap, 100), height: max(topH - gap, 100)),
                    CGRect(x: region.x + halfGap, y: region.y + topH + halfGap,
                           width: max(region.width - gap, 100), height: max(botH - gap, 100))
                ]
            } else {
                // Side by side
                let leftW = region.width * splitRatio
                let rightW = region.width * (1.0 - splitRatio)
                return [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(leftW - gap, 100), height: max(region.height - gap, 100)),
                    CGRect(x: region.x + leftW + halfGap, y: region.y + halfGap,
                           width: max(rightW - gap, 100), height: max(region.height - gap, 100))
                ]
            }

        case 3:
            if variant == 1 {
                // Stacked: three rows
                let rowH = region.height / 3.0
                return (0..<3).map { i in
                    CGRect(x: region.x + halfGap, y: region.y + rowH * CGFloat(i) + halfGap,
                           width: max(region.width - gap, 100), height: max(rowH - gap, 100))
                }
            } else {
                // Left half + top-right quarter + bottom-right quarter
                let leftW = region.width * splitRatio
                let rightW = region.width * (1.0 - splitRatio)
                let halfHeight = region.height / 2.0
                return [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(leftW - gap, 100), height: max(region.height - gap, 100)),
                    CGRect(x: region.x + leftW + halfGap, y: region.y + halfGap,
                           width: max(rightW - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + leftW + halfGap, y: region.y + halfHeight + halfGap,
                           width: max(rightW - gap, 100), height: max(halfHeight - gap, 100))
                ]
            }

        default:
            if variant == 1 {
                // Stacked: equal rows
                let rowH = region.height / CGFloat(count)
                return (0..<count).map { i in
                    CGRect(x: region.x + halfGap, y: region.y + rowH * CGFloat(i) + halfGap,
                           width: max(region.width - gap, 100), height: max(rowH - gap, 100))
                }
            } else {
                // 4+ windows: four quarters
                let halfWidth = region.width / 2.0
                let halfHeight = region.height / 2.0
                var frames = [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + halfWidth + halfGap, y: region.y + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + halfGap, y: region.y + halfHeight + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + halfWidth + halfGap, y: region.y + halfHeight + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100))
                ]
                for _ in 4..<count { frames.append(frames[3]) }
                return frames
            }
        }
    }

    // MARK: - Niri Scrolling Column Layout

    struct NiriColumnResult {
        let columnIndex: Int
        let windowFrames: [(windowID: CGWindowID, frame: CGRect)]
        let isVisible: Bool
    }

    /// Calculate frames for Niri scrolling column mode.
    /// Each column may contain multiple windows stacked vertically.
    /// The active column is centered on screen; off-screen columns are hidden.
    static func calculateNiriFrames(
        columns: [NiriColumn],
        region: TilingRegion,
        gap: CGFloat,
        activeColumn: Int,
        defaultColumnWidth: CGFloat
    ) -> [NiriColumnResult] {
        guard !columns.isEmpty else { return [] }

        let halfGap = gap / 2
        let clampedActive = max(0, min(activeColumn, columns.count - 1))

        // Compute each column's width in pixels
        let colWidths: [CGFloat] = columns.map { col in
            let fraction = col.widthOverride ?? defaultColumnWidth
            return region.width * fraction
        }

        // Layout columns sequentially in the virtual strip
        var colXPositions: [CGFloat] = []
        var x: CGFloat = 0
        for w in colWidths {
            colXPositions.append(x)
            x += w
        }

        // Find the center of the active column in the strip
        let activeX = colXPositions[clampedActive]
        let activeW = colWidths[clampedActive]
        let activeCenterInStrip = activeX + activeW / 2

        // Offset so the active column center aligns with the screen center
        let screenCenterX = region.x + region.width / 2
        let offset = screenCenterX - activeCenterInStrip

        // Build results
        var results: [NiriColumnResult] = []
        let screenLeft = region.x
        let screenRight = region.x + region.width

        for (i, col) in columns.enumerated() {
            let colX = colXPositions[i] + offset
            let colW = colWidths[i]

            let isVisible = (colX + colW) > screenLeft && colX < screenRight

            // Divide height equally among windows in this column
            let windowCount = col.windows.count
            var windowFrames: [(windowID: CGWindowID, frame: CGRect)] = []

            if windowCount > 0 {
                let totalHeight = region.height
                let windowHeight = totalHeight / CGFloat(windowCount)

                for (wi, wid) in col.windows.enumerated() {
                    let frame = CGRect(
                        x: colX + halfGap,
                        y: region.y + windowHeight * CGFloat(wi) + halfGap,
                        width: max(colW - gap, 100),
                        height: max(windowHeight - gap, 100)
                    )
                    windowFrames.append((windowID: wid, frame: frame))
                }
            }

            results.append(NiriColumnResult(
                columnIndex: i,
                windowFrames: windowFrames,
                isVisible: isVisible
            ))
        }

        return results
    }

    // MARK: - High-Level Layout

    /// Apply layout to N windows with smooth animation.
    static func applyLayout(
        windows: [(windowID: CGWindowID, element: AXUIElement, pid: pid_t)],
        region: TilingRegion,
        gap: CGFloat,
        singleWindowPadding: CGFloat = 0,
        splitRatio: CGFloat = 0.5,
        variant: Int = 0,
        animate: Bool = true
    ) {
        guard !windows.isEmpty else { return }

        let targetFrames = calculateFrames(
            count: windows.count, region: region, gap: gap,
            singleWindowPadding: singleWindowPadding,
            splitRatio: splitRatio, variant: variant
        )

        if animate {
            var transitions: [Animator.Transition] = []
            for (i, w) in windows.enumerated() where i < targetFrames.count {
                let currentFrame = AccessibilityBridge.getFrame(of: w.element) ?? targetFrames[i]
                transitions.append(Animator.Transition(
                    windowID: w.windowID,
                    element: w.element,
                    startFrame: currentFrame,
                    targetFrame: targetFrames[i]
                ))
            }
            Animator.shared.animate(transitions)
        } else {
            // Snap immediately (used during mouse drag resize)
            var frames: [(element: AXUIElement, frame: CGRect)] = []
            for (i, w) in windows.enumerated() where i < targetFrames.count {
                frames.append((w.element, targetFrames[i]))
            }
            AccessibilityBridge.batchSetFrames(frames)
        }
    }
}
