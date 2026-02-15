import Cocoa

/// GPU-composited animation engine using SLSSetWindowTransform.
///
/// Instead of calling AX frame-setting APIs every frame (expensive IPC),
/// this engine:
/// 1. Sets windows to their FINAL position in one batched AX call
/// 2. Applies a reverse CGS transform so they visually appear at the START
/// 3. Animates the transform back to identity — all frames are GPU-composited
/// 4. Clears the transform at the end
///
/// This is the same technique yabai uses. Each animation frame is a single
/// CGS call per window (no IPC to the app), handled entirely by the compositor.
class Animator: NSObject {
    static let shared = Animator()

    var duration: CFTimeInterval = 0.15
    var enabled: Bool = true

    private var animationTimer: DispatchSourceTimer?
    private var activeTransitions: [Transition] = []
    private var animationStartTime: CFTimeInterval = 0
    private var isAnimating = false
    private let conn = CGSMainConnectionID()

    /// Whether SLSSetWindowTransform is available (checked once at startup)
    private let hasGPUTransform: Bool = {
        return dlsym(dlopen(nil, RTLD_LAZY), "SLSSetWindowTransform") != nil
    }()

    struct Transition {
        let windowID: CGWindowID
        let element: AXUIElement
        let startFrame: CGRect
        let targetFrame: CGRect
    }

    /// Animate windows from current to target positions using GPU-composited transforms.
    func animate(_ transitions: [Transition]) {
        cancelAll()

        guard enabled, !transitions.isEmpty else {
            // Animation disabled — snap instantly
            let frames = transitions.map { (element: $0.element, frame: $0.targetFrame) }
            if !frames.isEmpty {
                AccessibilityBridge.batchSetFrames(frames)
            }
            return
        }

        // Filter to windows that actually need to move
        var moving: [Transition] = []
        for t in transitions {
            if !framesClose(t.startFrame, t.targetFrame) {
                moving.append(t)
            }
        }

        guard !moving.isEmpty else { return }

        // Small movements: just snap
        let maxDelta = moving.map {
            max(abs($0.startFrame.origin.x - $0.targetFrame.origin.x),
                abs($0.startFrame.origin.y - $0.targetFrame.origin.y),
                abs($0.startFrame.size.width - $0.targetFrame.size.width),
                abs($0.startFrame.size.height - $0.targetFrame.size.height))
        }.max() ?? 0

        if maxDelta < 15 {
            let frames = moving.map { (element: $0.element, frame: $0.targetFrame) }
            AccessibilityBridge.batchSetFrames(frames)
            return
        }

        // Use GPU transform path if available, otherwise fall back to AX interpolation
        if hasGPUTransform {
            animateWithGPUTransform(moving)
        } else {
            animateWithAXFrames(moving)
        }
    }

    // MARK: - GPU Transform Animation (yabai-style)

    private func animateWithGPUTransform(_ transitions: [Transition]) {
        activeTransitions = transitions

        // Phase 1: Suppress all redraws, set windows to FINAL position, apply reverse transform
        SLSDisableUpdate(conn)

        // Set final frames via AX (one batch call — the ONLY AX call in the entire animation)
        let finalFrames = transitions.map { (element: $0.element, frame: $0.targetFrame) }
        AccessibilityBridge.batchSetFrames(finalFrames)

        // Apply reverse transform so windows visually appear at their START positions
        for t in transitions {
            let transform = reverseTransform(start: t.startFrame, target: t.targetFrame)
            SLSSetWindowTransform(conn, t.windowID, transform)
        }

        SLSReenableUpdate(conn)

        // Phase 2: Animate transforms from reverse → identity
        animationStartTime = CACurrentMediaTime()
        isAnimating = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.tickGPU()
        }
        animationTimer = timer
        timer.resume()
    }

    private func tickGPU() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / duration), 1.0)
        // Ease-out quint — aggressive deceleration, snaps into place
        let t = 1.0 - pow(1.0 - linear, 5.0)

        SLSDisableUpdate(conn)

        if linear >= 1.0 {
            // Final: clear all transforms (windows show at their real final position)
            for tr in activeTransitions {
                SLSSetWindowTransform(conn, tr.windowID, .identity)
            }
            SLSReenableUpdate(conn)

            animationTimer?.cancel()
            animationTimer = nil
            activeTransitions.removeAll()
            isAnimating = false
            return
        }

        // Interpolate each window's transform from reverse toward identity
        for tr in activeTransitions {
            let dx = (tr.startFrame.origin.x - tr.targetFrame.origin.x) * (1.0 - t)
            let dy = (tr.startFrame.origin.y - tr.targetFrame.origin.y) * (1.0 - t)

            // Interpolate scale if sizes differ
            let sx = tr.targetFrame.width > 0 ? tr.startFrame.width / tr.targetFrame.width : 1.0
            let sy = tr.targetFrame.height > 0 ? tr.startFrame.height / tr.targetFrame.height : 1.0
            let currentSX = 1.0 + (sx - 1.0) * (1.0 - t)
            let currentSY = 1.0 + (sy - 1.0) * (1.0 - t)

            var transform = CGAffineTransform(translationX: dx, y: dy)
            if abs(currentSX - 1.0) > 0.001 || abs(currentSY - 1.0) > 0.001 {
                transform = transform.scaledBy(x: currentSX, y: currentSY)
            }

            SLSSetWindowTransform(conn, tr.windowID, transform)
        }

        SLSReenableUpdate(conn)
    }

    /// Calculate the reverse transform that makes a window at targetFrame visually appear at startFrame.
    private func reverseTransform(start: CGRect, target: CGRect) -> CGAffineTransform {
        let dx = start.origin.x - target.origin.x
        let dy = start.origin.y - target.origin.y

        let sx = target.width > 0 ? start.width / target.width : 1.0
        let sy = target.height > 0 ? start.height / target.height : 1.0

        var transform = CGAffineTransform(translationX: dx, y: dy)
        if abs(sx - 1.0) > 0.01 || abs(sy - 1.0) > 0.01 {
            transform = transform.scaledBy(x: sx, y: sy)
        }
        return transform
    }

    // MARK: - AX Frame Animation (fallback)

    private func animateWithAXFrames(_ transitions: [Transition]) {
        activeTransitions = transitions
        animationStartTime = CACurrentMediaTime()
        isAnimating = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.tickAX()
        }
        animationTimer = timer
        timer.resume()
    }

    private func tickAX() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / duration), 1.0)
        let t = 1.0 - pow(1.0 - linear, 5.0)

        var frames: [(element: AXUIElement, frame: CGRect)] = []
        for tr in activeTransitions {
            let x = tr.startFrame.origin.x + (tr.targetFrame.origin.x - tr.startFrame.origin.x) * t
            let y = tr.startFrame.origin.y + (tr.targetFrame.origin.y - tr.startFrame.origin.y) * t
            let w = tr.startFrame.size.width + (tr.targetFrame.size.width - tr.startFrame.size.width) * t
            let h = tr.startFrame.size.height + (tr.targetFrame.size.height - tr.startFrame.size.height) * t
            frames.append((tr.element, CGRect(x: x, y: y, width: w, height: h)))
        }

        AccessibilityBridge.batchSetFrames(frames)

        if linear >= 1.0 {
            let finalFrames = activeTransitions.map { (element: $0.element, frame: $0.targetFrame) }
            AccessibilityBridge.batchSetFrames(finalFrames)
            cancelAll()
        }
    }

    // MARK: - Cleanup

    func cancelAll() {
        if isAnimating && hasGPUTransform {
            // Reset all transforms to identity so windows show at their real position
            SLSDisableUpdate(conn)
            for t in activeTransitions {
                SLSSetWindowTransform(conn, t.windowID, .identity)
            }
            SLSReenableUpdate(conn)
        }
        animationTimer?.cancel()
        animationTimer = nil
        activeTransitions.removeAll()
        isAnimating = false
    }

    /// Reset transforms for a set of window IDs (crash recovery on startup).
    func resetTransforms(for windowIDs: [CGWindowID]) {
        guard hasGPUTransform else { return }
        SLSDisableUpdate(conn)
        for wid in windowIDs {
            SLSSetWindowTransform(conn, wid, .identity)
        }
        SLSReenableUpdate(conn)
    }

    private func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 5 &&
        abs(a.origin.y - b.origin.y) < 5 &&
        abs(a.size.width - b.size.width) < 5 &&
        abs(a.size.height - b.size.height) < 5
    }
}
