import Foundation

/// Writes a changed config back into the file as it stands, instead of over it.
///
/// Settings used to write the whole file afresh on every change, which threw away every
/// comment in it and any line Paneless did not write itself. `merge` keeps the file and
/// changes only what changed: a value is replaced on its own line, a new entry joins the end
/// of its section, an entry that is gone leaves, and everything else (comments, blank lines,
/// keys Paneless does not know) stays where it was. Nothing in here reads the disk, so every
/// rule is pinned by a test.
enum ConfigText {
    /// The keys Paneless reads in the sections that have a fixed set of them. A line in one of
    /// these sections with any other key is not ours to remove.
    static let fixedKeys: [String: Set<String>] = [
        "layout": [
            "inner_gap", "outer_gap", "animations", "size_once", "app_driven_animation",
            "native_animation", "single_window_padding", "focus_follows_mouse", "force_promotion",
            "auto_float_dialogs", "focus_follows_app", "dim_unfocused", "tiling_mode",
            "niri_column_width", "niri_min_column_width", "niri_column_stack", "niri_fill_screen",
            "hyperkey",
        ],
        "border": ["enabled", "width", "active_color", "inactive_color", "radius"],
        "rules": ["float", "exclude", "sticky", "swallow", "swallow_all"],
        "menubar": ["active_color", "inactive_color"],
    ]

    /// Sections that are a list of entries, each one Paneless's to add and remove.
    static let listSections: Set<String> = ["app_rules", "workspaces", "bindings"]

    private struct Entry {
        let key: String
        let line: String
    }

    /// `existing` with the values of `rendered` written into it. `rendered` is the whole
    /// config as Paneless would write it from nothing, and is returned as it is when there
    /// is no file yet.
    static func merge(existing: String?, rendered: String) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rendered
        }

        var order: [String] = []
        var entries: [String: [Entry]] = [:]
        var section = ""
        for line in rendered.components(separatedBy: "\n") {
            if let name = sectionName(line) {
                section = name
                if entries[name] == nil {
                    order.append(name)
                    entries[name] = []
                }
            } else if let key = entryKey(line, section: section) {
                entries[section, default: []].append(Entry(key: key, line: line))
            }
        }

        var out: [String] = []
        var used: [String: Set<String>] = [:]
        var seen: Set<String> = []
        // Where the current section's new entries go: after its last line that is not a
        // comment or blank, so they sit with the others and above any trailing comment.
        var sectionEnd = 0
        section = ""

        func addNewEntries() {
            let fresh = (entries[section] ?? []).filter { !(used[section] ?? []).contains($0.key) }
            guard !fresh.isEmpty else { return }
            out.insert(contentsOf: fresh.map(\.line), at: sectionEnd)
            used[section, default: []].formUnion(fresh.map(\.key))
        }

        for line in existing.components(separatedBy: "\n") {
            if let name = sectionName(line) {
                addNewEntries()
                section = name
                seen.insert(name)
                out.append(line)
                sectionEnd = out.count
                continue
            }
            guard let key = entryKey(line, section: section) else {
                out.append(line)
                continue
            }
            if (used[section] ?? []).contains(key) { continue }
            if let entry = entries[section]?.first(where: { $0.key == key }) {
                out.append(entry.line)
                used[section, default: []].insert(key)
                sectionEnd = out.count
            } else if listSections.contains(section) || fixedKeys[section]?.contains(key) == true {
                continue
            } else {
                out.append(line)
                sectionEnd = out.count
            }
        }
        addNewEntries()

        for name in order where !seen.contains(name) {
            guard let fresh = entries[name], !fresh.isEmpty else { continue }
            while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
            out.append("")
            out.append("[\(name)]")
            out.append(contentsOf: fresh.map(\.line))
        }

        var text = out.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private static func sectionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    /// What names a `key = value` line within its section, or nil for a comment, a blank or
    /// anything else that is not one. Read as `PanelessConfig.load` reads it.
    private static func entryKey(_ line: String, section: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || sectionName(line) != nil { return nil }
        let parts = trimmed.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        return section == "bindings" ? bindingKey(key) : key
    }

    /// A shortcut whatever way it is spelled: "cmd+shift, h", "shift+cmd, H" and
    /// "command+shift,h" are the same keys, so the line is updated where it stands.
    static func bindingKey(_ key: String) -> String {
        let parts = key.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return key.lowercased() }
        let names: [String: String] = [
            "opt": "alt", "option": "alt", "command": "cmd", "super": "cmd", "control": "ctrl",
        ]
        var modifiers = Set(parts[0].lowercased().split(separator: "+").map { part -> String in
            let name = part.trimmingCharacters(in: .whitespaces)
            return names[name] ?? name
        })
        if modifiers.contains("hyper") { modifiers = ["hyper"] }
        if modifiers.isSuperset(of: ["ctrl", "alt", "cmd", "shift"]) { modifiers = ["hyper"] }
        let keyName = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        return modifiers.sorted().joined(separator: "+") + "," + keyName
    }
}
