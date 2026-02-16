import Cocoa

/// GPU-composited animation engine using SLSSetWindowTransform.
///
/// Uses the same cubic bezier curves and timing as Hyprland for that
/// buttery-smooth feel: aggressive ease-out where 95% of movement
/// happens in the first ~100ms, with a long settling tail.
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
    private var closeDuration: CFTimeInterval = 0
    private var closeCompletion: (() -> Void)?

    /// Whether SLSSetWindowTransform is available (checked once at startup)
    private let hasGPUTransform: Bool = {
        return dlsym(dlopen(nil, RTLD_LAZY), "SLSSetWindowTransform") != nil
    }()

    // MARK: - Hyprland Bezier Curves

    /// Hyprland's easeOutQuint: bezier(0.23, 1, 0.32, 1)
    /// 95% of movement in first ~20% of duration — fast snap with smooth settle
    private let easeOutQuint = BezierCurve(p1x: 0.23, p1y: 1.0, p2x: 0.32, p2y: 1.0)

    /// Hyprland's almostLinear: bezier(0.5, 0.5, 0.75, 1.0)
    /// Used for fades and close animations
    private let almostLinear = BezierCurve(p1x: 0.5, p1y: 0.5, p2x: 0.75, p2y: 1.0)

    // Exact Hyprland default durations (from hyprland.conf defaults)
    private let windowMoveDuration: CFTimeInterval = 0.479   // 4.79ds — animation = windows
    private let windowOpenDuration: CFTimeInterval = 0.41    // 4.1ds  — animation = windowsIn (popin 87%)
    private let windowCloseDuration: CFTimeInterval = 0.149  // 1.49ds — animation = windowsOut (popin 87%)

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

        /// Evaluate the curve: given a time fraction x (0→1), return the eased value y (0→1).
        /// Uses Newton-Raphson iteration to invert the x→t mapping.
        func evaluate(_ x: CGFloat) -> CGFloat {
            guard x > 0 else { return 0 }
            guard x < 1 else { return 1 }

            // Newton-Raphson: find parameter t where bezierX(t) = x
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

        /// Cubic bezier component: B(t) = 3(1-t)²t·p1 + 3(1-t)t²·p2 + t³
        private func bezierComponent(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
            let mt = 1.0 - t
            return 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t
        }

        /// Derivative of cubic bezier component
        private func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
            let mt = 1.0 - t
            return 3.0 * mt * mt * p1 + 6.0 * mt * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
        }
    }

    // MARK: - Public API

    /// Animate windows from current to target positions using GPU-composited transforms.
    func animate(_ transitions: [Transition]) {
        cancelAll()

        guard enabled, !transitions.isEmpty else {
            let frames = transitions.map { (element: $0.element, frame: $0.targetFrame) }
            if !frames.isEmpty {
                AccessibilityBridge.batchSetFrames(frames)
            }
            return
        }

        var moving: [Transition] = []
        for t in transitions {
            if !framesClose(t.startFrame, t.targetFrame) {
                moving.append(t)
            }
        }

        guard !moving.isEmpty else { return }

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

        // Pick duration: if any window is new, use open duration; otherwise move duration
        let hasNewWindow = moving.contains { $0.isNewWindow }
        let duration = hasNewWindow ? windowOpenDuration : windowMoveDuration

        if hasGPUTransform {
            animateGPU(moving, duration: duration)
        } else {
            animateAX(moving, duration: duration)
        }
    }

    /// Animate redistribute + close: remaining windows fill the gap while
    /// the closing window shrinks and fades out (Hyprland popin style).
    func animateWithClose(
        redistributeTransitions: [Transition],
        closingWindowID: CGWindowID,
        closingFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        cancelAll()

        guard enabled, hasGPUTransform else {
            let frames = redistributeTransitions.map { (element: $0.element, frame: $0.targetFrame) }
            if !frames.isEmpty { AccessibilityBridge.batchSetFrames(frames) }
            completion()
            return
        }

        self.closingWindowID = closingWindowID
        self.closingFrame = closingFrame
        self.closeDuration = windowCloseDuration
        self.closeCompletion = completion

        var moving: [Transition] = []
        for t in redistributeTransitions {
            if !framesClose(t.startFrame, t.targetFrame) {
                moving.append(t)
            }
        }
        activeTransitions = moving

        SLSDisableUpdate(conn)

        let finalFrames = moving.map { (element: $0.element, frame: $0.targetFrame) }
        AccessibilityBridge.batchSetFrames(finalFrames)

        for t in moving {
            SLSSetWindowTransform(conn, t.windowID, centerAnchoredTransform(start: t.startFrame, target: t.targetFrame))
        }
        SLSSetWindowTransform(conn, closingWindowID, .identity)

        SLSReenableUpdate(conn)

        // Use the longer of close duration or move duration
        let animDuration = max(windowCloseDuration, windowMoveDuration)
        startTimer(duration: animDuration, tick: tickGPUWithClose)
    }

    // MARK: - GPU Transform Animation

    private var currentDuration: CFTimeInterval = 0

    private func animateGPU(_ transitions: [Transition], duration: CFTimeInterval) {
        activeTransitions = transitions

        SLSDisableUpdate(conn)

        let finalFrames = transitions.map { (element: $0.element, frame: $0.targetFrame) }
        AccessibilityBridge.batchSetFrames(finalFrames)

        for t in transitions {
            SLSSetWindowTransform(conn, t.windowID, centerAnchoredTransform(start: t.startFrame, target: t.targetFrame))
            // New windows start hidden (alpha set to 0 in windowCreated).
            // Set initial alpha=0 in the same atomic batch so they appear
            // at the correct position when we fade them in.
            if t.isNewWindow {
                CGSSetWindowAlpha(conn, t.windowID, 0.0)
            }
        }

        SLSReenableUpdate(conn)
        startTimer(duration: duration, tick: tickGPU)
    }

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

    private func tickGPU() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / currentDuration), 1.0)
        let t = easeOutQuint.evaluate(linear)

        SLSDisableUpdate(conn)

        if linear >= 1.0 {
            for tr in activeTransitions {
                SLSSetWindowTransform(conn, tr.windowID, .identity)
                if tr.isNewWindow {
                    CGSSetWindowAlpha(conn, tr.windowID, 1.0)
                }
            }
            SLSReenableUpdate(conn)
            finishAnimation()
            return
        }

        for tr in activeTransitions {
            SLSSetWindowTransform(conn, tr.windowID, interpolatedTransform(transition: tr, progress: t))
            // Fade in new windows: alpha follows the easing curve (fast rise)
            if tr.isNewWindow {
                CGSSetWindowAlpha(conn, tr.windowID, Float(t))
            }
        }
        SLSReenableUpdate(conn)
    }

    private func tickGPUWithClose() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime

        // Redistribute uses move duration with easeOutQuint
        let redistLinear = min(CGFloat(elapsed / windowMoveDuration), 1.0)
        let redistT = easeOutQuint.evaluate(redistLinear)

        // Close uses close duration with almostLinear
        let closeLinear = min(CGFloat(elapsed / windowCloseDuration), 1.0)
        let closeT = almostLinear.evaluate(closeLinear)

        let allDone = redistLinear >= 1.0 && closeLinear >= 1.0

        SLSDisableUpdate(conn)

        if allDone {
            for tr in activeTransitions {
                SLSSetWindowTransform(conn, tr.windowID, .identity)
            }
            if let closingWID = closingWindowID {
                SLSSetWindowTransform(conn, closingWID, .identity)
                CGSSetWindowAlpha(conn, closingWID, 0.0)
            }
            SLSReenableUpdate(conn)

            let completion = self.closeCompletion
            finishAnimation()
            closingWindowID = nil
            closingFrame = .zero
            closeCompletion = nil
            completion?()
            return
        }

        // Redistribute remaining windows
        if redistLinear < 1.0 {
            for tr in activeTransitions {
                SLSSetWindowTransform(conn, tr.windowID, interpolatedTransform(transition: tr, progress: redistT))
            }
        } else {
            for tr in activeTransitions {
                SLSSetWindowTransform(conn, tr.windowID, .identity)
            }
        }

        // Close: Hyprland popin 87% + fade
        if let closingWID = closingWindowID, closeLinear < 1.0 {
            let s = 1.0 - (0.13 * closeT)  // 1.0 → 0.87 (Hyprland popin 87%)
            let alpha = Float(1.0 - closeT)

            let tx = closingFrame.width * (1.0 - s) / 2.0
            let ty = closingFrame.height * (1.0 - s) / 2.0
            SLSSetWindowTransform(conn, closingWID, CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
            CGSSetWindowAlpha(conn, closingWID, alpha)
        }

        SLSReenableUpdate(conn)
    }

    // MARK: - Center-Anchored Transform Math

    private func centerAnchoredTransform(start: CGRect, target: CGRect) -> CGAffineTransform {
        let sx = target.width > 0 ? start.width / target.width : 1.0
        let sy = target.height > 0 ? start.height / target.height : 1.0
        let centerDX = start.midX - target.midX
        let centerDY = start.midY - target.midY

        if abs(sx - 1.0) < 0.01 && abs(sy - 1.0) < 0.01 {
            return CGAffineTransform(translationX: centerDX, y: centerDY)
        }

        let tx = target.width * (1.0 - sx) / 2.0 + centerDX
        let ty = target.height * (1.0 - sy) / 2.0 + centerDY
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }

    private func interpolatedTransform(transition tr: Transition, progress t: CGFloat) -> CGAffineTransform {
        let sx = tr.targetFrame.width > 0 ? tr.startFrame.width / tr.targetFrame.width : 1.0
        let sy = tr.targetFrame.height > 0 ? tr.startFrame.height / tr.targetFrame.height : 1.0
        let centerDX = tr.startFrame.midX - tr.targetFrame.midX
        let centerDY = tr.startFrame.midY - tr.targetFrame.midY

        let currentSX = 1.0 + (sx - 1.0) * (1.0 - t)
        let currentSY = 1.0 + (sy - 1.0) * (1.0 - t)
        let currentDX = centerDX * (1.0 - t)
        let currentDY = centerDY * (1.0 - t)

        if abs(currentSX - 1.0) < 0.001 && abs(currentSY - 1.0) < 0.001 {
            return CGAffineTransform(translationX: currentDX, y: currentDY)
        }

        let tx = tr.targetFrame.width * (1.0 - currentSX) / 2.0 + currentDX
        let ty = tr.targetFrame.height * (1.0 - currentSY) / 2.0 + currentDY
        return CGAffineTransform(a: currentSX, b: 0, c: 0, d: currentSY, tx: tx, ty: ty)
    }

    // MARK: - AX Frame Animation (fallback)

    private func animateAX(_ transitions: [Transition], duration: CFTimeInterval) {
        activeTransitions = transitions
        // Fade in new windows even in AX fallback mode
        for t in transitions where t.isNewWindow {
            CGSSetWindowAlpha(conn, t.windowID, 0.0)
        }
        startTimer(duration: duration, tick: tickAX)
    }

    private func tickAX() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / currentDuration), 1.0)
        let t = easeOutQuint.evaluate(linear)

        var frames: [(element: AXUIElement, frame: CGRect)] = []
        for tr in activeTransitions {
            let x = tr.startFrame.origin.x + (tr.targetFrame.origin.x - tr.startFrame.origin.x) * t
            let y = tr.startFrame.origin.y + (tr.targetFrame.origin.y - tr.startFrame.origin.y) * t
            let w = tr.startFrame.size.width + (tr.targetFrame.size.width - tr.startFrame.size.width) * t
            let h = tr.startFrame.size.height + (tr.targetFrame.size.height - tr.startFrame.size.height) * t
            frames.append((tr.element, CGRect(x: x, y: y, width: w, height: h)))
            if tr.isNewWindow {
                CGSSetWindowAlpha(conn, tr.windowID, Float(t))
            }
        }

        AccessibilityBridge.batchSetFrames(frames)

        if linear >= 1.0 {
            let finalFrames = activeTransitions.map { (element: $0.element, frame: $0.targetFrame) }
            AccessibilityBridge.batchSetFrames(finalFrames)
            for tr in activeTransitions where tr.isNewWindow {
                CGSSetWindowAlpha(conn, tr.windowID, 1.0)
            }
            cancelAll()
        }
    }

    // MARK: - Cleanup

    private func finishAnimation() {
        animationTimer?.cancel()
        animationTimer = nil
        activeTransitions.removeAll()
        isAnimating = false
    }

    func cancelAll() {
        if isAnimating && hasGPUTransform {
            SLSDisableUpdate(conn)
            for t in activeTransitions {
                SLSSetWindowTransform(conn, t.windowID, .identity)
                // Restore alpha for new windows that were fading in
                if t.isNewWindow {
                    CGSSetWindowAlpha(conn, t.windowID, 1.0)
                }
            }
            if let closingWID = closingWindowID {
                SLSSetWindowTransform(conn, closingWID, .identity)
                CGSSetWindowAlpha(conn, closingWID, 1.0)
            }
            SLSReenableUpdate(conn)
        }
        animationTimer?.cancel()
        animationTimer = nil
        activeTransitions.removeAll()
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

    private func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 5 &&
        abs(a.origin.y - b.origin.y) < 5 &&
        abs(a.size.width - b.size.width) < 5 &&
        abs(a.size.height - b.size.height) < 5
    }
}
