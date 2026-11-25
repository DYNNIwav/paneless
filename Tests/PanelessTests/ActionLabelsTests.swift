import Testing
@testable import Paneless

@Suite struct ActionLabelsTests {
    /// Every action the config reads has a plain name, and reads back as the same action.
    @Test func everyFixedActionIsOneTheConfigReads() {
        for choice in ActionLabels.fixed {
            let action = PanelessConfig.parseAction(choice.value)
            #expect(action != nil, "\(choice.value)")
            #expect(action.flatMap(PanelessConfig.actionString) == choice.value, "\(choice.value)")
            #expect(choice.label != choice.value)
        }
        #expect(Set(ActionLabels.fixed.map(\.value)).count == ActionLabels.fixed.count)
    }

    /// The actions the old list lacked: each has a name, none shows as its config spelling.
    @Test func columnMovesMarksAndAppTogglesHaveNames() {
        for action in ["niri_move_left", "niri_move_right", "niri_move_up", "niri_move_down",
                       "niri_move_column_left", "niri_move_column_right"] {
            #expect(ActionLabels.label(for: action) != action)
        }
        #expect(ActionLabels.label(for: "set_mark a") == "Set mark a")
        #expect(ActionLabels.label(for: "jump_mark b") == "Jump to mark b")
        #expect(ActionLabels.label(for: "toggle_app Terminal") == "Open or hide Terminal")
        #expect(ActionLabels.label(for: "move_to_workspace 3") == "Move window to workspace 3")
        #expect(ActionLabels.label(for: "switch_workspace 2") == "Go to workspace 2")
    }

    /// The editor lists a shortcut's own action, so it shows selected and is not lost.
    @Test func theEditorOffersTheShortcutsOwnAction() {
        #expect(ActionLabels.choices(including: "close") == ActionLabels.fixed)
        let marks = ActionLabels.choices(including: "set_mark a")
        #expect(marks.count == ActionLabels.fixed.count + 1)
        #expect(marks.last == ActionLabels.Choice(label: "Set mark a", value: "set_mark a"))
    }
}
