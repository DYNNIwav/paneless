import Cocoa

/// Window animation engine.
///
/// On macOS Tahoe+, SLSSetWindowTransform works for SCALE transforms
/// (popin/close effects) but not for pure TRANSLATION (window moves).
/// So we use compositor scale+fade for open/close, and instant atomic
/// batchSetFrames for position moves.
class Animator: NSObject {
    static let shared = Animator()

    var enabled: Bool = true

    private var animationTimer: DispatchSourceTimer?
    private var activeTransitions: [Transition] = []
    private var animationStartTime: CFTimeInterval = 0
    private var isAnimating = false
    private let conn = CGSMainConnectionID()

    // Close animation state
    private var closingWindowID: CGWindowID?
    private var closingFrame: CGRect = .zero
    private var closeCompletion: (() -> Void)?

    /// Whether SLSSetWindowTransform is available (checked once at startup)
    private let hasGPUTransform: Bool = {
        return dlsym(dlopen(nil, RTLD_LAZY), "SLSSetWindowTransform") != nil
    }()

    // MARK: - Hyprland Animation Curves & Timing

    /// Hyprland's "default" bezier: (0.25, 1, 0.5, 1) — smooth ease-out
    private let easeOut = BezierCurve(p1x: 0.25, p1y: 1.0, p2x: 0.5, p2y: 1.0)

    /// Hyprland's almostLinear: bezier(0.5, 0.5, 0.75, 1.0)
    private let almostLinear = BezierCurve(p1x: 0.5, p1y: 0.5, p2x: 0.75, p2y: 1.0)

    // Hyprland default durations & scale
    private let windowOpenDuration: CFTimeInterval = 0.5     // popin 80%
    private let windowCloseDuration: CFTimeInterval = 0.2     // popout 80%
    private let popinScale: CGFloat = 0.80                    // Hyprland default: popin 80%

    struct Transition {
        let windowID: CGWindowID
        let element: AXUIElement
        let startFrame: CGRect
        let targetFrame: CGRect
        var isNewWindow: Bool = false
    }

    /// Cubic bezier curve evaluator (same math as CSS/Hyprland beziers).
    struct BezierCurve {
        let p1x: CGFloat, p1y: CGFloat
        let p2x: CGFloat, p2y: CGFloat

        func evaluate(_ x: CGFloat) -> CGFloat {
            guard x > 0 else { return 0 }
            guard x < 1 else { return 1 }

            var t = x
            for _ in 0..<8 {
                let bx = bezierComponent(t, p1: p1x, p2: p2x)
                let dbx = bezierDerivative(t, p1: p1x, p2: p2x)
                if abs(dbx) < 1e-7 { break }
                t -= (bx - x) / dbx
                t = max(0, min(1, t))
            }
            return bezierComponent(t, p1: p1y, p2: p2y)
        }

        private func bezierComponent(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
            let mt = 1.0 - t
            return 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t
        }

        private func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
            let mt = 1.0 - t
            return 3.0 * mt * mt * p1 + 6.0 * mt * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
        }
    }

    // MARK: - Public API

    // Delayed popin state
    private var pendingPopinWork: DispatchWorkItem?

    /// Move windows to their target positions.
    /// Position moves are instant (atomic batchSetFrames).
    /// New windows get a GPU-composited popin scale + fade-in after a short
    /// delay to let existing windows finish resizing first (avoids overlap
    /// with slow apps like Messages).
    func animate(_ transitions: [Transition]) {
        cancelAll()
        guard !transitions.isEmpty else { return }

        var newWindows: [Transition] = []
        var frames: [(element: AXUIElement, frame: CGRect)] = []

        for t in transitions {
            frames.append((element: t.element, frame: t.targetFrame))
            if t.isNewWindow {
                newWindows.append(t)
            }
        }

        // Atomic batch move: reposition existing windows + place new window hidden
        SLSDisableUpdate(conn)

        for w in newWindows {
            CGSSetWindowAlpha(conn, w.windowID, 0.0)
        }

        // Apply initial scale transform so new window is ready at 80% when it fades in
        if enabled && hasGPUTransform {
            for w in newWindows {
                let tx = w.targetFrame.width * (1.0 - popinScale) / 2.0
                let ty = w.targetFrame.height * (1.0 - popinScale) / 2.0
                SLSSetWindowTransform(conn, w.windowID,
                    CGAffineTransform(a: popinScale, b: 0, c: 0, d: popinScale, tx: tx, ty: ty))
            }
        }

        AccessibilityBridge.batchSetFrames(frames)

        SLSReenableUpdate(conn)

        // Start popin after a delay so slow apps have time to resize
        if enabled && hasGPUTransform && !newWindows.isEmpty {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.activeTransitions = newWindows
                self.startTimer(duration: self.windowOpenDuration, tick: self.tickPopin)
            }
            pendingPopinWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        } else if !newWindows.isEmpty {
            for w in newWindows {
                CGSSetWindowAlpha(conn, w.windowID, 1.0)
            }
        }
    }

    /// Snap remaining windows to new positions + animate closing window
    /// with popout shrink + fade.
    func animateWithClose(
        redistributeTransitions: [Transition],
        closingWindowID: CGWindowID,
        closingFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        cancelAll()

        self.closingWindowID = closingWindowID
        self.closingFrame = closingFrame
        self.closeCompletion = completion

        let frames = redistributeTransitions.map { (element: $0.element, frame: $0.targetFrame) }

        SLSDisableUpdate(conn)
        if !frames.isEmpty {
            AccessibilityBridge.batchSetFrames(frames)
        }
        // Start close animation: identity transform (full size)
        if hasGPUTransform {
            SLSSetWindowTransform(conn, closingWindowID, .identity)
        }
        SLSReenableUpdate(conn)

        if enabled && hasGPUTransform {
            startTimer(duration: windowCloseDuration, tick: tickClose)
        } else {
            CGSSetWindowAlpha(conn, closingWindowID, 0.0)
            let cb = self.closeCompletion
            self.closingWindowID = nil
            self.closingFrame = .zero
            self.closeCompletion = nil
            cb?()
        }
    }

    // MARK: - Popin Animation (new window: scale 87%→100% + fade in)

    private var currentDuration: CFTimeInterval = 0

    private func tickPopin() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / currentDuration), 1.0)
        let t = easeOut.evaluate(linear)

        SLSDisableUpdate(conn)

        if linear >= 1.0 {
            for tr in activeTransitions {
                SLSSetWindowTransform(conn, tr.windowID, .identity)
                CGSSetWindowAlpha(conn, tr.windowID, 1.0)
            }
            SLSReenableUpdate(conn)
            finishAnimation()
            return
        }

        // Scale: popinScale → 1.0, alpha: 0 → 1
        let growth = 1.0 - popinScale  // 0.20 for 80% popin
        for tr in activeTransitions {
            let scale = popinScale + growth * t  // 0.80 → 1.0
            let tx = tr.targetFrame.width * (1.0 - scale) / 2.0
            let ty = tr.targetFrame.height * (1.0 - scale) / 2.0
            SLSSetWindowTransform(conn, tr.windowID,
                CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty))
            CGSSetWindowAlpha(conn, tr.windowID, Float(t))
        }
        SLSReenableUpdate(conn)
    }

    // MARK: - Close Animation (popout: scale 100%→87% + fade out)

    private func tickClose() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / currentDuration), 1.0)
        let t = almostLinear.evaluate(linear)

        SLSDisableUpdate(conn)

        if linear >= 1.0 {
            if let closingWID = closingWindowID {
                SLSSetWindowTransform(conn, closingWID, .identity)
                CGSSetWindowAlpha(conn, closingWID, 0.0)
            }
            SLSReenableUpdate(conn)

            let cb = self.closeCompletion
            finishAnimation()
            closingWindowID = nil
            closingFrame = .zero
            closeCompletion = nil
            cb?()
            return
        }

        // Scale: 1.0 → popinScale (80%), alpha: 1 → 0
        if let closingWID = closingWindowID {
            let shrink = 1.0 - popinScale  // 0.20
            let scale = 1.0 - (shrink * t)  // 1.0 → 0.80
            let alpha = Float(1.0 - t)
            let tx = closingFrame.width * (1.0 - scale) / 2.0
            let ty = closingFrame.height * (1.0 - scale) / 2.0
            SLSSetWindowTransform(conn, closingWID,
                CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty))
            CGSSetWindowAlpha(conn, closingWID, alpha)
        }
        SLSReenableUpdate(conn)
    }

    // MARK: - Timer

    private func startTimer(duration: CFTimeInterval, tick: @escaping () -> Void) {
        currentDuration = duration
        animationStartTime = CACurrentMediaTime()
        isAnimating = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { tick() }
        animationTimer = timer
        timer.resume()
    }

    // MARK: - Cleanup

    private func finishAnimation() {
        animationTimer?.cancel()
        animationTimer = nil
        activeTransitions.removeAll()
        isAnimating = false
    }

    func cancelAll() {
        // Cancel pending delayed popin
        pendingPopinWork?.cancel()
        pendingPopinWork = nil

        if isAnimating {
            if hasGPUTransform {
                SLSDisableUpdate(conn)
                for t in activeTransitions {
                    SLSSetWindowTransform(conn, t.windowID, .identity)
                    CGSSetWindowAlpha(conn, t.windowID, 1.0)
                }
                if let closingWID = closingWindowID {
                    SLSSetWindowTransform(conn, closingWID, .identity)
                    CGSSetWindowAlpha(conn, closingWID, 1.0)
                }
                SLSReenableUpdate(conn)
            }
        }
        animationTimer?.cancel()
        animationTimer = nil
        activeTransitions.removeAll()
        if let cb = closeCompletion { cb() }
        closingWindowID = nil
        closingFrame = .zero
        closeCompletion = nil
        isAnimating = false
    }

    func resetTransforms(for windowIDs: [CGWindowID]) {
        guard hasGPUTransform else { return }
        SLSDisableUpdate(conn)
        for wid in windowIDs {
            SLSSetWindowTransform(conn, wid, .identity)
        }
        SLSReenableUpdate(conn)
    }
}
