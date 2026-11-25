import CoreGraphics

/// The column widths Settings offers. The slider it replaces moved in steps of a tenth, so
/// it could not rest on a third, and touching it lost a width of 0.333.
enum ColumnWidth: String, CaseIterable, Identifiable {
    case third, half, twoThirds, full
    /// A width set by hand in the config that is none of the four. Kept until another is picked.
    case custom

    var id: String { rawValue }

    /// The fraction of the screen written to the config, or nil for a width set by hand.
    var fraction: CGFloat? {
        switch self {
        case .third: return 0.333
        case .half: return 0.5
        case .twoThirds: return 0.667
        case .full: return 1.0
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .third: return "Third"
        case .half: return "Half"
        case .twoThirds: return "Two thirds"
        case .full: return "Full"
        case .custom: return "Custom"
        }
    }

    /// The choice a width in the config shows as: one of the four within a hundredth, as the
    /// menu bar names them, else custom.
    static func choice(for width: CGFloat) -> ColumnWidth {
        for candidate in [ColumnWidth.third, .half, .twoThirds, .full] {
            if let fraction = candidate.fraction, abs(width - fraction) < 0.01 { return candidate }
        }
        return .custom
    }

    /// What Settings lists: the four, and custom only while the width is one.
    static func choices(for width: CGFloat) -> [ColumnWidth] {
        choice(for: width) == .custom ? allCases : [.third, .half, .twoThirds, .full]
    }
}
