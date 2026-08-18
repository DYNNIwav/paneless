import Cocoa

/// Hyprland-style window borders. Draws colored overlay windows around the focused
/// (and optionally inactive) tiled windows.
class BorderManager {
    static let shared = BorderManager()

    var config: BorderConfig = BorderConfig()

    private var activeBorder: NSWindow?
    private var inactiveBorders: [CGWindowID: NSWindow] = [:]
    private var currentFocusedID: CGWindowID?

    /// Update the border for the currently focused window
    func updateFocus(windowID: CGWindowID?, frame: CGRect?) {
        guard config.enabled else {
            removeAll()
            return
        }

        currentFocusedID = windowID

        guard let windowID = windowID, let frame = frame else {
            activeBorder?.orderOut(nil)
            activeBorder = nil
            return
        }

        // Slide the existing border to the newly focused window rather than destroying
        // it and building another. The border is one of the few things on screen we own
        // outright, so unlike a real window it can be animated freely and always looks
        // smooth no matter how slow the app underneath is.
        if let border = activeBorder {
            let cocoa = axToCocoaFrame(borderRect(for: frame))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                border.animator().setFrame(cocoa, display: true)
            }
            border.order(.below, relativeTo: Int(windowID))
            return
        }

        // No border yet: fade the first one in instead of snapping it on.
        let created = makeBorderWindow(frame: frame, color: config.activeColor)
        created.alphaValue = 0
        activeBorder = created
        created.order(.below, relativeTo: Int(windowID))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            created.animator().alphaValue = 1
        }
    }

    /// Update border positions after a retile (windows may have moved)
    func updatePositions(layouts: [(CGWindowID, CGRect)], focusedID: CGWindowID?) {
        guard config.enabled else { return }

        // Update active border position
        if let focusedID = focusedID,
           let layout = layouts.first(where: { $0.0 == focusedID }) {
            if let border = activeBorder {
                let borderFrame = borderRect(for: layout.1)
                let cocoaFrame = axToCocoaFrame(borderFrame)
                // Arrive a little before the window does. Moving the eye to where
                // something is about to happen makes the motion that follows read as
                // smoother than it measures, and the border can always keep the pace.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.26
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    border.animator().setFrame(cocoaFrame, display: true)
                }
                border.order(.below, relativeTo: Int(focusedID))
            } else {
                activeBorder = makeBorderWindow(frame: layout.1, color: config.activeColor)
                activeBorder?.order(.below, relativeTo: Int(focusedID))
            }
        }
    }

    func removeAll() {
        activeBorder?.orderOut(nil)
        activeBorder = nil
        for (_, border) in inactiveBorders {
            border.orderOut(nil)
        }
        inactiveBorders.removeAll()
        currentFocusedID = nil
    }

    // MARK: - Private

    private func makeBorderWindow(frame: CGRect, color: NSColor) -> NSWindow {
        let borderFrame = borderRect(for: frame)
        let cocoaFrame = axToCocoaFrame(borderFrame)

        let window = NSWindow(
            contentRect: cocoaFrame,
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

        // The stroke center sits at borderWidth/2 from the border window edge.
        // To make the inner stroke edge match the window's corner radius,
        // the path radius = windowRadius + borderWidth/2.
        let pathRadius = config.radius + config.width / 2

        let borderView = BorderView(
            frame: NSRect(origin: .zero, size: cocoaFrame.size),
            borderColor: color,
            borderWidth: config.width,
            cornerRadius: pathRadius
        )
        window.contentView = borderView

        return window
    }

    /// Expand the window frame by the border width to surround it.
    /// The border overlaps slightly under the window so there's no gap.
    private func borderRect(for windowFrame: CGRect) -> CGRect {
        let inset = config.width
        return windowFrame.insetBy(dx: -inset, dy: -inset)
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
}

// MARK: - Border View

private class BorderView: NSView {
    let borderColor: NSColor
    let borderWidth: CGFloat
    let cornerRadius: CGFloat

    init(frame: NSRect, borderColor: NSColor, borderWidth: CGFloat, cornerRadius: CGFloat) {
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.clear(bounds)

        let insetRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let path = CGPath(roundedRect: insetRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)
        context.addPath(path)
        context.strokePath()
    }
}
