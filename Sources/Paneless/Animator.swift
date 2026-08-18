import Cocoa
import CoreVideo

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
    /// Matches what macOS's own tiling takes (measured 330ms for TextEdit, 355ms for Safari).
    private let windowMoveDuration: CFTimeInterval = 0.33

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
    /// Move windows to their target positions.
    ///
    /// Every window walks from its current frame to its target over `windowMoveDuration`,
    /// paced by the display link. This is the same thing macOS's own tiling does: measured
    /// on this machine, Apple animates the real window frame at roughly 115 updates/sec for
    /// a light window and 73/sec for Safari. There is no compositor shortcut available to
    /// us, because SLSSetWindowTransform and CGSSetWindowAlpha both no-op on windows owned
    /// by another process, so the frame is the only thing that actually moves.
    func animate(_ transitions: [Transition]) {
        cancelAll()
        guard !transitions.isEmpty else { return }

        let targets = transitions.map { (element: $0.element, frame: $0.targetFrame) }

        guard enabled else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }

        var steps: [Glide] = []
        var pids = Set<pid_t>()
        for t in transitions {
            let from = t.startFrame.width > 1 ? t.startFrame
                                              : (AccessibilityBridge.getFrame(of: t.element) ?? t.targetFrame)
            // Nothing to watch if it is already there.
            guard abs(from.origin.x - t.targetFrame.origin.x) > 1
                || abs(from.origin.y - t.targetFrame.origin.y) > 1
                || abs(from.width - t.targetFrame.width) > 1
                || abs(from.height - t.targetFrame.height) > 1 else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(t.element, &pid)
            pids.insert(pid)
            steps.append(Glide(windowID: t.windowID, element: t.element, from: from, to: t.targetFrame))
        }

        guard !steps.isEmpty else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }

        startGlide(steps, targets: targets, pids: pids)
    }

    // MARK: - Frame Glide

    struct Glide {
        let windowID: CGWindowID
        let element: AXUIElement
        let from: CGRect
        let to: CGRect
    }

    private var glides: [Glide] = []
    private var glideTargets: [(element: AXUIElement, frame: CGRect)] = []
    private var glideStartTime: CFTimeInterval = 0
    private var restoreEnhancedUI: Set<pid_t> = []
    private var displayLink: CVDisplayLink?
    private let glideLock = NSLock()
    private var busyWindows = Set<CGWindowID>()
    /// Concurrent so a slow app blocks only its own window, not the whole frame.
    /// Each app is a separate AX server, so these genuinely overlap.
    private let axQueue = DispatchQueue(label: "com.paneless.axglide", attributes: .concurrent)

    private func startGlide(_ steps: [Glide],
                            targets: [(element: AXUIElement, frame: CGRect)],
                            pids: Set<pid_t>) {
        glideLock.lock()
        glides = steps
        glideTargets = targets
        glideStartTime = CACurrentMediaTime()
        busyWindows.removeAll()
        glideLock.unlock()

        // Off for the duration, so the apps don't animate against us.
        restoreEnhancedUI = AccessibilityBridge.setEnhancedUI(pids: pids, enabled: false)
        isAnimating = true

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link = link else {
            AccessibilityBridge.batchSetFrames(targets)
            finishGlide()
            return
        }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.glideTick()
            return kCVReturnSuccess
        }
        displayLink = link
        CVDisplayLinkStart(link)
    }

    private func glideTick() {
        glideLock.lock()
        let steps = glides
        let started = glideStartTime
        glideLock.unlock()

        guard !steps.isEmpty else { return }

        let linear = min(CGFloat((CACurrentMediaTime() - started) / windowMoveDuration), 1.0)
        if linear >= 1.0 {
            DispatchQueue.main.async { [weak self] in self?.finishGlide(commit: true) }
            return
        }

        let e = easeOut.evaluate(linear)
        for g in steps {
            // Skip any window still busy with its previous write. A slow app then simply
            // updates less often instead of backing up a queue of stale frames.
            glideLock.lock()
            let busy = busyWindows.contains(g.windowID)
            if !busy { busyWindows.insert(g.windowID) }
            glideLock.unlock()
            guard !busy else { continue }

            let rect = CGRect(
                x: g.from.origin.x + (g.to.origin.x - g.from.origin.x) * e,
                y: g.from.origin.y + (g.to.origin.y - g.from.origin.y) * e,
                width: g.from.width + (g.to.width - g.from.width) * e,
                height: g.from.height + (g.to.height - g.from.height) * e
            )
            axQueue.async { [weak self] in
                AccessibilityBridge.setFrameDuringAnimation(of: g.element, to: rect)
                guard let self = self else { return }
                self.glideLock.lock()
                self.busyWindows.remove(g.windowID)
                self.glideLock.unlock()
            }
        }
    }

    private func finishGlide(commit: Bool = false) {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        let targets = glideTargets
        if commit && !targets.isEmpty {
            // Land exactly on the target, whatever the last interpolated frame was.
            AccessibilityBridge.batchSetFrames(targets)
        }
        if !restoreEnhancedUI.isEmpty {
            AccessibilityBridge.setEnhancedUI(pids: restoreEnhancedUI, enabled: true)
            restoreEnhancedUI = []
        }
        glideLock.lock()
        glides = []
        glideTargets = []
        busyWindows.removeAll()
        glideLock.unlock()
        isAnimating = false
    }

    /// Snap remaining windows to new positions + animate closing window
    /// with popout shrink + fade.
    /// Close a window and flow the remaining ones into the space it leaves.
    ///
    /// The closing window itself cannot be animated: shrinking or fading it would need
    /// SLSSetWindowTransform or CGSSetWindowAlpha, and both are no-ops on windows owned
    /// by another process. So it goes at once, and the windows that remain glide into
    /// their new frames, which is where the motion actually reads from.
    func animateWithClose(
        redistributeTransitions: [Transition],
        closingWindowID: CGWindowID,
        closingFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        cancelAll()

        // Close first so the gap is real before anything moves into it.
        completion()

        guard enabled, !redistributeTransitions.isEmpty else {
            if !redistributeTransitions.isEmpty {
                AccessibilityBridge.batchSetFrames(
                    redistributeTransitions.map { (element: $0.element, frame: $0.targetFrame) })
            }
            return
        }

        let targets = redistributeTransitions.map { (element: $0.element, frame: $0.targetFrame) }
        var steps: [Glide] = []
        var pids = Set<pid_t>()
        for t in redistributeTransitions {
            let from = t.startFrame.width > 1 ? t.startFrame
                                              : (AccessibilityBridge.getFrame(of: t.element) ?? t.targetFrame)
            guard abs(from.origin.x - t.targetFrame.origin.x) > 1
                || abs(from.origin.y - t.targetFrame.origin.y) > 1
                || abs(from.width - t.targetFrame.width) > 1
                || abs(from.height - t.targetFrame.height) > 1 else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(t.element, &pid)
            pids.insert(pid)
            steps.append(Glide(windowID: t.windowID, element: t.element, from: from, to: t.targetFrame))
        }

        guard !steps.isEmpty else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }
        startGlide(steps, targets: targets, pids: pids)
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

        // Stop any frame glide. Don't commit: whoever cancelled is about to set
        // its own targets, and committing here would fight them.
        if displayLink != nil || !glides.isEmpty {
            finishGlide()
        }

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
