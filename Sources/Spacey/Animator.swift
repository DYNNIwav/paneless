import Cocoa

/// Lightweight animation engine using direct AX frame interpolation.
/// Smoothly transitions windows from current to target positions at 120fps.
class Animator {
    static let shared = Animator()

    var duration: CFTimeInterval = 0.15
    var enabled: Bool = true

    private var animationTimer: DispatchSourceTimer?
    private var activeTransitions: [Transition] = []
    private var animationStartTime: CFTimeInterval = 0
    private var isAnimating = false

    struct Transition {
        let windowID: CGWindowID
        let element: AXUIElement
        let startFrame: CGRect
        let targetFrame: CGRect
    }

    /// Animate windows from current to target positions.
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

        if maxDelta < 30 {
            let frames = moving.map { (element: $0.element, frame: $0.targetFrame) }
            AccessibilityBridge.batchSetFrames(frames)
            return
        }

        activeTransitions = moving
        animationStartTime = CACurrentMediaTime()
        isAnimating = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        animationTimer = timer
        timer.resume()
    }

    func cancelAll() {
        animationTimer?.cancel()
        animationTimer = nil
        activeTransitions.removeAll()
        isAnimating = false
    }

    // MARK: - Animation Tick

    private func tick() {
        guard isAnimating else { return }

        let elapsed = CACurrentMediaTime() - animationStartTime
        let linear = min(CGFloat(elapsed / duration), 1.0)
        // Ease-out cubic for snappy feel
        let t = 1.0 - pow(1.0 - linear, 3.0)

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
            // Final snap to exact target
            let finalFrames = activeTransitions.map { (element: $0.element, frame: $0.targetFrame) }
            AccessibilityBridge.batchSetFrames(finalFrames)
            cancelAll()
        }
    }

    private func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 5 &&
        abs(a.origin.y - b.origin.y) < 5 &&
        abs(a.size.width - b.size.width) < 5 &&
        abs(a.size.height - b.size.height) < 5
    }
}
