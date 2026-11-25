import Foundation
import Testing
@testable import Paneless

@Suite struct ConfigTextTests {
    let file = """
        # My config, do not lose this line

        [layout]
        # roomy gaps on the big screen
        inner_gap = 8
        outer_gap = 8
        my_own_note = keep me
        hyperkey = f18

        [rules]
        float = Finder

        [bindings]
        # moving around
        cmd+shift, h = position_left
        alt, x = close
        """

    @Test func aChangedValueIsWrittenOnItsOwnLineAndEveryCommentStays() {
        let merged = ConfigText.merge(existing: file, rendered: """
            # Paneless Configuration

            [layout]
            inner_gap = 12
            outer_gap = 8
            hyperkey = f18

            [rules]
            float = Finder

            [bindings]
            shift+cmd, h = position_left
            alt, x = close
            """)
        #expect(merged == file.replacingOccurrences(of: "inner_gap = 8", with: "inner_gap = 12")
            .replacingOccurrences(of: "cmd+shift, h = position_left", with: "shift+cmd, h = position_left") + "\n")
    }

    @Test func anEntryThatIsGoneLeavesAndALineThatIsNotOursStays() {
        let merged = ConfigText.merge(existing: file, rendered: """
            [layout]
            inner_gap = 8
            outer_gap = 8

            [rules]
            float = Finder

            [bindings]
            shift+cmd, h = position_left
            """)
        #expect(!merged.contains("hyperkey"))
        #expect(!merged.contains("alt, x = close"))
        #expect(merged.contains("my_own_note = keep me"))
        #expect(merged.contains("# moving around"))
        #expect(merged.contains("# My config, do not lose this line"))
    }

    @Test func aNewEntryJoinsTheEndOfItsSectionAndANewSectionTheEndOfTheFile() throws {
        let merged = ConfigText.merge(existing: file, rendered: """
            [layout]
            inner_gap = 8
            outer_gap = 8
            dim_unfocused = 0.1
            hyperkey = f18

            [rules]
            float = Finder
            sticky = Spotify

            [workspaces]
            1 = Code

            [bindings]
            shift+cmd, h = position_left
            alt, x = close
            """)
        let lines = merged.components(separatedBy: "\n")
        let hyper = try #require(lines.firstIndex(of: "hyperkey = f18"))
        #expect(lines[hyper + 1] == "dim_unfocused = 0.1")
        #expect(lines[hyper + 2] == "")
        let float = try #require(lines.firstIndex(of: "float = Finder"))
        #expect(lines[float + 1] == "sticky = Spotify")
        #expect(merged.hasSuffix("alt, x = close\n\n[workspaces]\n1 = Code\n"))
    }

    @Test func withNoFileTheWholeConfigIsWritten() {
        #expect(ConfigText.merge(existing: nil, rendered: "[layout]\ninner_gap = 8") == "[layout]\ninner_gap = 8")
        #expect(ConfigText.merge(existing: " \n", rendered: "[layout]\ninner_gap = 8") == "[layout]\ninner_gap = 8")
    }

    @Test func aShortcutIsTheSameHoweverItIsSpelled() {
        #expect(ConfigText.bindingKey("cmd+shift, h") == ConfigText.bindingKey("Shift+Command,H"))
        #expect(ConfigText.bindingKey("opt, 1") == ConfigText.bindingKey("alt, 1"))
        #expect(ConfigText.bindingKey("ctrl+alt+cmd+shift, k") == ConfigText.bindingKey("hyper, k"))
        #expect(ConfigText.bindingKey("alt, h") != ConfigText.bindingKey("alt+shift, h"))
    }

    /// A config Paneless wrote itself comes back unchanged, so saving twice changes nothing.
    @Test func whatPanelessWroteMergesIntoItselfUnchanged() {
        var config = PanelessConfig()
        config.workspaceNames = [1: "Code"]
        config.appWorkspaceRules = ["Slack": 3]
        let text = config.rendered()
        #expect(ConfigText.merge(existing: text, rendered: text) == text)
    }

    @Test func aRuleKeepsWhatWasWrittenAndHidesOnlyTheBundleIDsItsNamesStandFor() {
        var config = PanelessConfig()
        config.floatApps = ["Finder", "Draw.io", "com.example.tool"]
        config.addBundleIDs()
        #expect(config.floatApps.contains("com.apple.finder"))
        #expect(PanelessConfig.written(config.floatApps) == ["Draw.io", "Finder", "com.example.tool"])
        #expect(config.rendered().contains("float = Draw.io, Finder, com.example.tool"))
        #expect(PanelessConfig.written(PanelessConfig().swallowApps) == ["Alacritty", "Ghostty", "Terminal", "WezTerm", "iTerm2", "kitty"])
    }

    /// The column settings are written in either mode, so a spell in the other mode keeps them.
    @Test func columnSettingsAreWrittenInEitherMode() {
        var config = PanelessConfig()
        config.tilingMode = "hyprland"
        config.niriColumnWidth = 0.333
        #expect(config.rendered().contains("niri_column_width = 0.333"))
    }
}
