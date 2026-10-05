import CoreGraphics

/// How an arriving window enters its tile.
enum ScaleIn {
    /// The pop-in start: four fifths of the tile, around its centre.
    static func popin(_ target: CGRect) -> CGRect {
        let scale: CGFloat = 0.80
        return CGRect(x: target.midX - target.width * scale / 2,
                      y: target.midY - target.height * scale / 2,
                      width: target.width * scale, height: target.height * scale)
    }

    /// Where an arriving window glides from when it is not really new, or nil for a
    /// genuinely new window that gets the entrance. A window we tiled before is back
    /// from Cmd+H or a minimise, and one already on its tile has nowhere to go. Both
    /// shrinking to the pop-in and regrowing read as the window jittering.
    static func settledStart(target: CGRect, actual: CGRect?, tiledBefore: Bool) -> CGRect? {
        if tiledBefore { return actual ?? target }
        guard let actual,
              abs(actual.minX - target.minX) <= 1, abs(actual.minY - target.minY) <= 1,
              abs(actual.width - target.width) <= 1, abs(actual.height - target.height) <= 1
        else { return nil }
        return actual
    }
}
