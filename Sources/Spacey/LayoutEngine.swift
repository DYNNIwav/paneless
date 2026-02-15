import Cocoa

/// Simple ordered window list layout engine.
/// Replaces BSP tree with direct frame calculation for 1-4 windows.
class LayoutEngine {
    var tiledWindows: [CGWindowID] = []
    var config: SpaceyConfig
    var layoutVariant: Int = 0
    var splitRatio: CGFloat = 0.5

    init(config: SpaceyConfig) {
        self.config = config
    }

    func cycleVariant() {
        layoutVariant = (layoutVariant + 1) % NativeTiling.variantCount
    }

    // MARK: - Window Management

    func insert(windowID: CGWindowID, afterFocused focusedID: CGWindowID?) {
        guard !tiledWindows.contains(windowID) else { return }

        if let focusedID = focusedID, let idx = tiledWindows.firstIndex(of: focusedID) {
            tiledWindows.insert(windowID, at: idx + 1)
        } else {
            tiledWindows.append(windowID)
        }
    }

    func remove(windowID: CGWindowID) {
        tiledWindows.removeAll { $0 == windowID }
    }

    func contains(_ windowID: CGWindowID) -> Bool {
        return tiledWindows.contains(windowID)
    }

    var windowCount: Int {
        return tiledWindows.count
    }

    // MARK: - Layout Calculation

    /// Calculate frames for all tiled windows.
    /// - 1 window: fill
    /// - 2 windows: left half + right half
    /// - 3 windows: left half + top-right quarter + bottom-right quarter
    /// - 4+ windows: four quarters (extras share bottom-right)
    func calculateFrames(in region: TilingRegion) -> [(CGWindowID, CGRect)] {
        let frames = NativeTiling.calculateFrames(
            count: tiledWindows.count,
            region: region,
            gap: config.innerGap,
            singleWindowPadding: config.singleWindowPadding,
            splitRatio: splitRatio,
            variant: layoutVariant
        )

        var result: [(CGWindowID, CGRect)] = []
        for (i, windowID) in tiledWindows.enumerated() where i < frames.count {
            result.append((windowID, frames[i]))
        }
        return result
    }

    // MARK: - Neighbor Finding

    func getNeighbor(of windowID: CGWindowID, direction: Direction,
                     layouts: [(CGWindowID, CGRect)]) -> CGWindowID? {
        guard let currentLayout = layouts.first(where: { $0.0 == windowID }) else { return nil }

        let currentRect = currentLayout.1
        let cx = currentRect.midX
        let cy = currentRect.midY

        var bestCandidate: (CGWindowID, CGFloat)?

        for (id, rect) in layouts where id != windowID {
            let ox = rect.midX
            let oy = rect.midY

            let isInDirection: Bool
            switch direction {
            case .left:  isInDirection = ox < cx
            case .right: isInDirection = ox > cx
            case .up:    isInDirection = oy < cy
            case .down:  isInDirection = oy > cy
            }

            guard isInDirection else { continue }

            let distance = hypot(ox - cx, oy - cy)
            if bestCandidate == nil || distance < bestCandidate!.1 {
                bestCandidate = (id, distance)
            }
        }

        return bestCandidate?.0
    }

    // MARK: - Swap with First (Master)

    func swapWithFirst(_ windowID: CGWindowID) {
        guard tiledWindows.count >= 2 else { return }
        guard let idx = tiledWindows.firstIndex(of: windowID), idx != 0 else { return }
        tiledWindows.swapAt(0, idx)
    }

    // MARK: - Rotation

    /// Rotate windows forward: last becomes first, everything shifts right.
    /// [A, B, C] → [C, A, B]
    func rotateNext() {
        guard tiledWindows.count >= 2 else { return }
        let last = tiledWindows.removeLast()
        tiledWindows.insert(last, at: 0)
    }

    /// Rotate windows backward: first becomes last, everything shifts left.
    /// [A, B, C] → [B, C, A]
    func rotatePrev() {
        guard tiledWindows.count >= 2 else { return }
        let first = tiledWindows.removeFirst()
        tiledWindows.append(first)
    }
}
