import Foundation

/// The plain name of every action a shortcut can run, for the Keys tab.
///
/// The tab used to keep its own shorter list, so a shortcut for an action missing from it
/// (a mark, a move between columns, an app toggle) showed as its config name and opened an
/// editor with nothing selected. Every action `PanelessConfig.parseAction` reads has a name
/// here, and a test holds the two together.
enum ActionLabels {
    struct Choice: Equatable {
        let label: String
        let value: String
    }

    /// Actions that take no argument of their own, in the order the editor lists them.
    static let fixed: [Choice] = [
        Choice(label: "Focus next", value: "focus_next"),
        Choice(label: "Focus previous", value: "focus_prev"),
        Choice(label: "Focus left", value: "focus_left"),
        Choice(label: "Focus right", value: "focus_right"),
        Choice(label: "Focus up", value: "focus_up"),
        Choice(label: "Focus down", value: "focus_down"),
        Choice(label: "Swap with master", value: "swap_master"),
        Choice(label: "Rotate next", value: "rotate_next"),
        Choice(label: "Rotate previous", value: "rotate_prev"),
        Choice(label: "Cycle layout", value: "cycle_layout"),
        Choice(label: "Grow focused", value: "grow_focused"),
        Choice(label: "Shrink focused", value: "shrink_focused"),
        Choice(label: "Increase gap", value: "increase_gap"),
        Choice(label: "Decrease gap", value: "decrease_gap"),
        Choice(label: "Toggle float", value: "toggle_float"),
        Choice(label: "Toggle fullscreen", value: "toggle_fullscreen"),
        Choice(label: "Close window", value: "close"),
        Choice(label: "Minimize", value: "minimize"),
        Choice(label: "Position left", value: "position_left"),
        Choice(label: "Position right", value: "position_right"),
        Choice(label: "Position up", value: "position_up"),
        Choice(label: "Position down", value: "position_down"),
        Choice(label: "Position fill", value: "position_fill"),
        Choice(label: "Position center", value: "position_center"),
        Choice(label: "Focus monitor left", value: "focus_monitor left"),
        Choice(label: "Focus monitor right", value: "focus_monitor right"),
        Choice(label: "Move to monitor left", value: "move_to_monitor left"),
        Choice(label: "Move to monitor right", value: "move_to_monitor right"),
        Choice(label: "Move window left between columns", value: "niri_move_left"),
        Choice(label: "Move window right between columns", value: "niri_move_right"),
        Choice(label: "Move window up in its column", value: "niri_move_up"),
        Choice(label: "Move window down in its column", value: "niri_move_down"),
        Choice(label: "Move column left", value: "niri_move_column_left"),
        Choice(label: "Move column right", value: "niri_move_column_right"),
        Choice(label: "Join the column beside", value: "niri_consume"),
        Choice(label: "Leave the column", value: "niri_expel"),
        Choice(label: "Retile", value: "retile"),
        Choice(label: "Reload config", value: "reload_config"),
    ]

    /// The name shown for an action as the config spells it. One that carries an argument
    /// (a mark, an app, a workspace) is named with it.
    static func label(for action: String) -> String {
        if let known = fixed.first(where: { $0.value == action }) { return known.label }
        let parts = action.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return action }
        let argument = parts[1].trimmingCharacters(in: .whitespaces)
        switch parts[0].lowercased() {
        case "set_mark": return "Set mark \(argument)"
        case "jump_mark": return "Jump to mark \(argument)"
        case "toggle_app": return "Open or hide \(argument)"
        case "switch_workspace": return "Go to workspace \(argument)"
        case "move_to_workspace": return "Move window to workspace \(argument)"
        default: return action
        }
    }

    /// What the editor offers for a shortcut: every fixed action, and the shortcut's own
    /// action when it is one that carries an argument, so it is shown selected and is kept.
    static func choices(including current: String) -> [Choice] {
        if fixed.contains(where: { $0.value == current }) { return fixed }
        return fixed + [Choice(label: label(for: current), value: current)]
    }
}
