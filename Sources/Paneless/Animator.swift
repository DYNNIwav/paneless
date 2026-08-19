import Cocoa
import CoreVideo

/// Window animation engine.
///
/// Everything here goes through the Accessibility API, because that is the only
/// thing that works. Measured on macOS Tahoe with a controlled two-process test:
/// SLSSetWindowTransform and CGSSetWindowAlpha both return CGError 0 and do
/// nothing at all when the target window belongs to another process. They only
/// affect windows we own ourselves. This file used to claim the opposite and the
/// popin, popout and alpha pre-hide effects were all built on it, so none of them
/// ever ran. Do not add a compositor path back without measuring it first.
///
/// yabai gets a real GPU animation by capturing the window, animating its own
/// proxy, and asking Dock.app to hide the real one. That last step needs SIP
/// partially disabled, and capturing window pixels at all costs the Screen
/// Recording permission plus a permanently lit recording indicator, so neither
/// is available to us.
class Animator: NSObject {
    static let shared = Animator()

    var enabled: Bool = true
    /// Take the final size in one step at the start and animate position only.
    /// See Config.sizeOnce.
    var sizeOnce: Bool = false
    /// See Config.appDrivenAnimation.
    var appDrivenAnimation: Bool = false

    /// Called with true when an animation starts and false when the last one ends.
    /// Lets the owner run the ProMotion keepalive only while it is worth anything.
    var onAnimationActive: ((Bool) -> Void)?

    private var isAnimating = false
    private let conn = CGSMainConnectionID()

    // Close animation state


    // MARK: - Hyprland Animation Curves & Timing

    /// Hyprland's "default" bezier: (0.25, 1, 0.5, 1) — smooth ease-out
    private let easeOut = BezierCurve(p1x: 0.25, p1y: 1.0, p2x: 0.5, p2y: 1.0)


    // Hyprland default durations & scale
    /// Slight swing past the target, then settle. The overshoot is deliberately small:
    /// enough to read as weight, not enough to lap a neighbouring cell.
    private func easeOutBack(_ x: CGFloat) -> CGFloat {
        // Measured: c1 = 0.9 swung 57px past the target on a 1904pt window, enough to
        // lap the neighbouring cell. This is about a third of that.
        let c1: CGFloat = 0.32, c3 = c1 + 1
        let p = x - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    /// How far apart to start successive windows in one reflow.
    ///
    /// Zero: they move as one. A cascade was tried and it does read as choreographed,
    /// but windows sharing an edge then visibly slide out of step with each other, and
    /// the thing that makes a tiling layout feel solid is that neighbours behave as if
    /// they are pushing one another rather than each going its own way.
    private let staggerStep: TimeInterval = 0

    /// How long a new window waits before entering. The windows already on screen move
    /// aside first and the newcomer drops into the space they opened, rather than the
    /// two crossing over each other at the start, which reads as a collision.
    private let newWindowDelay: TimeInterval = 0.10

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
            // A new arrival leads and may swing past its mark; the others follow in a
            // short cascade, which reads as choreography rather than everything lurching
            // at once. Both are free: it only changes when each write is issued.
            steps.append(Glide(windowID: t.windowID, element: t.element,
                               from: from, to: t.targetFrame,
                               delay: t.isNewWindow ? newWindowDelay : Double(steps.count) * staggerStep,
                               overshoot: t.isNewWindow))
        }

        guard !steps.isEmpty else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }

        startAnimation(steps, targets: targets, pids: pids)
    }

    // MARK: - Frame Glide

    /// A reference type because the animation learns about the window as it runs.
    final class Glide {
        let windowID: CGWindowID
        let element: AXUIElement
        let from: CGRect
        let to: CGRect
        /// The window travels without changing size, so kAXSize is never written.
        let moveOnly: Bool
        /// Set once the app has demonstrated it will not take the size we ask for.
        /// Fixed-size windows and windows that snap to a character grid, like terminals,
        /// otherwise cost a full resize per frame and ignore every one of them.
        var sizeRefused = false
        /// Whether the first write has been checked against what the app actually did.
        var constraintChecked = false
        /// Seconds to wait before this window starts moving. Offsetting each window a
        /// little makes a reflow read as choreographed rather than mechanical, and it
        /// costs nothing: the writes are simply spread out.
        var delay: TimeInterval = 0
        /// Whether this window may swing slightly past its target and settle back.
        /// Only new arrivals do; a neighbour overshooting would lap into the window
        /// beside it, which in a tiling layout reads as a mistake rather than as life.
        var overshoot = false

        init(windowID: CGWindowID, element: AXUIElement, from: CGRect, to: CGRect,
             delay: TimeInterval = 0, overshoot: Bool = false) {
            self.delay = delay
            self.overshoot = overshoot
            self.windowID = windowID
            self.element = element
            self.from = from
            self.to = to
            self.moveOnly = abs(from.width - to.width) < 2 && abs(from.height - to.height) < 2
        }
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

    private func startAnimation(_ steps: [Glide],
                                targets: [(element: AXUIElement, frame: CGRect)],
                                pids: Set<pid_t>) {
        // Let the applications animate themselves whenever nothing is being resized.
        //
        // AXEnhancedUserInterface eases position and snaps size, which is why it is not
        // the general answer. But a scroll along the strip changes no sizes at all, so the
        // one thing it does badly never comes up, and the one thing it does well is
        // exactly what is wanted: 110fps from a single round trip per application instead
        // of a synchronous write per window per frame, on a main thread that has to reach
        // every other window in the same 8.33ms.
        if appDrivenAnimation || steps.allSatisfy({ $0.moveOnly }) {
            startAppDrivenAnimation(steps, pids: pids)
        } else {
            startGlide(steps, targets: targets, pids: pids)
        }
    }

    // MARK: - App-driven animation

    /// How long to leave AXEnhancedUserInterface on. The apps' own animation measured
    /// ~225ms; this leaves margin without holding the attribute a moment longer than
    /// needed, since it makes apps build and maintain their whole accessibility tree.
    private let appDrivenSettle: TimeInterval = 0.45
    private var appDrivenRestore: Set<pid_t> = []
    private var appDrivenWork: DispatchWorkItem?

    /// Give each app its destination once and let it animate itself.
    ///
    /// Every other window manager turns AXEnhancedUserInterface off before writing a
    /// frame, because windows then "keep animating" and a read-back mid-flight returns
    /// a value that is still moving, which breaks their verify-and-correct loops. We
    /// want the animation, so we turn it on instead. Measured on Ghostty and Safari:
    /// one write produces 22-27 frames over ~225ms, about 110fps, from a single IPC
    /// round trip rather than one per frame.
    ///
    /// What it does not do is animate size: of 56 observed changes only 2 were resizes.
    /// Position eases, size snaps.
    private func startAppDrivenAnimation(_ steps: [Glide], pids: Set<pid_t>) {
        appDrivenWork?.cancel()
        // Only restore the apps we actually changed, so an app that legitimately has
        // this on, with VoiceOver running for instance, is left alone.
        appDrivenRestore.formUnion(AccessibilityBridge.setEnhancedUI(pids: pids, enabled: true))
        isAnimating = true
        onAnimationActive?(true)

        for step in steps {
            AccessibilityBridge.setFrameDuringAnimation(of: step.element, to: step.to)
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            AccessibilityBridge.setEnhancedUI(pids: self.appDrivenRestore, enabled: false)
            self.appDrivenRestore = []
            self.appDrivenWork = nil
            self.isAnimating = false
            self.onAnimationActive?(false)
        }
        appDrivenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + appDrivenSettle, execute: work)
    }

    private func startGlide(_ steps: [Glide],
                            targets: [(element: AXUIElement, frame: CGRect)],
                            pids: Set<pid_t>) {
        glideLock.lock()
        glides = steps
        glideTargets = targets
        glideStartTime = CACurrentMediaTime()
        busyWindows.removeAll()
        glideLock.unlock()

        // A hung app must not be able to stall the loop for the multi-second AX default.
        // A glide that only moves a window gets a tight deadline; one that resizes keeps
        // the generous one it needs.
        //
        // Every write here is synchronous, so an application that takes its time holds up
        // the frame for all the others too. One timeout of a quarter of a second covered
        // both cases, which is thirty frames' worth at 120Hz for a write that measures
        // 0.2 to 2ms. This is a bound on the damage a hung application can do rather than
        // a measured win: 30ms is still fifteen times what a move needs, while a resize is
        // 25 to 53ms on Safari and would be cut off by anything tighter.
        for step in steps {
            AccessibilityBridge.limitMessagingTime(of: step.element, to: step.moveOnly ? 0.03 : 0.25)
        }

        // Pay every resize once, here, rather than forty times during the animation.
        // The window snaps to its final size and then travels at full frame rate.
        if sizeOnce {
            for step in steps where !step.moveOnly {
                var size = step.to.size
                if let v = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(step.element, kAXSizeAttribute as CFString, v)
                }
                step.sizeRefused = true
            }
        }

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
        onAnimationActive?(true)
        CVDisplayLinkStart(link)
    }

    private func glideTick() {
        glideLock.lock()
        let steps = glides
        let started = glideStartTime
        glideLock.unlock()

        guard !steps.isEmpty else { return }

        let elapsed = CACurrentMediaTime() - started
        let lastDelay = steps.map(\.delay).max() ?? 0
        if elapsed >= windowMoveDuration + lastDelay {
            DispatchQueue.main.async { [weak self] in self?.finishGlide(commit: true) }
            return
        }

        for g in steps {
            // Each window runs its own clock, offset by its place in the reflow.
            let own = min(max((elapsed - g.delay) / windowMoveDuration, 0), 1)
            guard own > 0 else { continue }
            let e = g.overshoot ? easeOutBack(CGFloat(own)) : easeOut.evaluate(CGFloat(own))
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
            guard AccessibilityBridge.isPlausibleFrame(rect) else {
                glideLock.lock(); busyWindows.remove(g.windowID); glideLock.unlock()
                continue
            }

            let wantsSize = !g.moveOnly && !g.sizeRefused
            axQueue.async { [weak self] in
                AccessibilityBridge.setFrameDuringAnimation(of: g.element, to: rect, setSize: wantsSize)

                // Ask once whether the app is actually honouring the size. If it gave us
                // something else, it is constrained, and every further resize this
                // animation would be paid for and thrown away.
                if wantsSize && !g.constraintChecked {
                    g.constraintChecked = true
                    if let actual = AccessibilityBridge.getFrame(of: g.element),
                       abs(actual.width - rect.width) > 2 || abs(actual.height - rect.height) > 2 {
                        g.sizeRefused = true
                    }
                }

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
        onAnimationActive?(false)
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
        closingElement: AXUIElement? = nil,
        completion: @escaping () -> Void
    ) {
        cancelAll()

        // Shrink the window before it goes, when we are the ones closing it.
        //
        // Only possible on Paneless's own close binding: a window closed with Cmd+W is
        // gone by the time we hear about it, and intercepting Cmd+W is not an option
        // because in a browser it closes a tab rather than a window. Scaling would be
        // the natural way to do this and is not available to us, so the frame itself is
        // stepped down. It is a handful of resizes on a window that is about to cease
        // existing, so the usual cost of a resize does not matter here.
        if enabled, let element = closingElement, closingFrame.width > 1 {
            let steps = 6
            let duration = 0.11
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let scale = 1.0 - 0.22 * t
                let w = closingFrame.width * scale, h = closingFrame.height * scale
                let rect = CGRect(x: closingFrame.midX - w / 2, y: closingFrame.midY - h / 2,
                                  width: w, height: h)
                DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) {
                    AccessibilityBridge.setFrameDuringAnimation(of: element, to: rect)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { completion() }
        } else {
            // Close first so the gap is real before anything moves into it.
            completion()
        }

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
            // A new arrival leads and may swing past its mark; the others follow in a
            // short cascade, which reads as choreography rather than everything lurching
            // at once. Both are free: it only changes when each write is issued.
            steps.append(Glide(windowID: t.windowID, element: t.element,
                               from: from, to: t.targetFrame,
                               delay: t.isNewWindow ? newWindowDelay : Double(steps.count) * staggerStep,
                               overshoot: t.isNewWindow))
        }

        guard !steps.isEmpty else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }
        startAnimation(steps, targets: targets, pids: pids)
    }

    // MARK: - Cleanup

    func cancelAll() {
        // Let an app-driven animation finish its restore rather than stranding the
        // attribute on; a queued restore is cheap and leaving it set is not.
        if let work = appDrivenWork {
            work.cancel()
            appDrivenWork = nil
            AccessibilityBridge.setEnhancedUI(pids: appDrivenRestore, enabled: false)
            appDrivenRestore = []
            isAnimating = false
        }

        // Stop any frame glide. Don't commit: whoever cancelled is about to set
        // its own targets, and committing here would fight them.
        if displayLink != nil || !glides.isEmpty {
            finishGlide()
        }
        isAnimating = false
    }

}
