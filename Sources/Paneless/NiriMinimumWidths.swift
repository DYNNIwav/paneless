import CoreGraphics

/// Width floors must be evidence of a refused resize, not an old window snapshot.
struct NiriMinimumWidths {
    var widths: [CGWindowID: CGFloat] = [:]
    private var targetsByMonitor: [String: [CGWindowID: CGSize]] = [:]
    private var candidates: [CGWindowID: CGFloat] = [:]
    private var attempts: [CGWindowID: Int] = [:]

    mutating func suspend() { candidates.removeAll() }

    mutating func remove(_ id: CGWindowID) {
        widths.removeValue(forKey: id)
        candidates.removeValue(forKey: id)
        attempts.removeValue(forKey: id)
    }

    mutating func prepare(monitor: String, targets: [CGWindowID: CGSize]) -> Bool {
        guard targetsByMonitor[monitor] != targets else { return false }
        let ids = Set(targets.keys).union(targetsByMonitor[monitor]?.keys.map { $0 } ?? [])
        targetsByMonitor[monitor] = targets
        var changed = false
        for id in ids {
            changed = widths.removeValue(forKey: id) != nil || changed
            candidates.removeValue(forKey: id)
            attempts.removeValue(forKey: id)
        }
        return changed
    }

    mutating func observe(_ id: CGWindowID, target: CGRect, settled: Bool,
                          read: () -> CGRect?, resize: (CGRect) -> Bool) -> Bool {
        guard settled else {
            candidates.removeValue(forKey: id)
            return false
        }
        guard let actual = read() else { return false }
        // A manual resize that accepted a narrower width disproves the old floor.
        if let minimum = widths[id], actual.width < minimum - 4 {
            widths.removeValue(forKey: id)
            candidates.removeValue(forKey: id)
            attempts.removeValue(forKey: id)
            return true
        }
        guard actual.width > target.width + 4, (attempts[id] ?? 0) < 3 else { return false }
        attempts[id, default: 0] += 1
        guard resize(target), let after = read(), after.width > target.width + 4,
              abs(after.height - target.height) <= 4 else {
            candidates.removeValue(forKey: id)
            return false
        }
        guard let previous = candidates[id], abs(previous - after.width) <= 4 else {
            candidates[id] = after.width
            return false
        }
        widths[id] = after.width
        candidates.removeValue(forKey: id)
        return true
    }
}
