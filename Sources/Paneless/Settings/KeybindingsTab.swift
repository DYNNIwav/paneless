import SwiftUI

// MARK: - UI-friendly binding model

struct EditableBinding: Identifiable, Equatable {
    let id: UUID
    var alt: Bool
    var shift: Bool
    var cmd: Bool
    var ctrl: Bool
    var keyName: String
    var action: String

    init(alt: Bool = false, shift: Bool = false, cmd: Bool = false, ctrl: Bool = false,
         keyName: String = "a", action: String = "focus_next") {
        self.id = UUID()
        self.alt = alt
        self.shift = shift
        self.cmd = cmd
        self.ctrl = ctrl
        self.keyName = keyName
        self.action = action
    }

    init(from binding: KeyBinding) {
        self.id = UUID()
        let flags = binding.modifiers
        self.alt = flags.contains(.maskAlternate)
        self.shift = flags.contains(.maskShift)
        self.cmd = flags.contains(.maskCommand)
        self.ctrl = flags.contains(.maskControl)
        self.keyName = KeyNames.keyName(for: binding.keyCode) ?? "?"
        self.action = PanelessConfig.actionString(binding.action) ?? "?"
    }

    var modifierFlags: CGEventFlags {
        var flags = CGEventFlags()
        if ctrl { flags.insert(.maskControl) }
        if alt { flags.insert(.maskAlternate) }
        if shift { flags.insert(.maskShift) }
        if cmd { flags.insert(.maskCommand) }
        return flags
    }

    var shortcutDisplay: String {
        var parts: [String] = []
        if ctrl && alt && cmd && shift {
            parts.append("Hyper")
        } else {
            if ctrl { parts.append("Ctrl") }
            if alt { parts.append("Opt") }
            if shift { parts.append("Shift") }
            if cmd { parts.append("Cmd") }
        }
        parts.append(KeybindingsTab.keyDisplayName(keyName))
        return parts.joined(separator: " + ")
    }

    func toKeyBinding() -> KeyBinding? {
        guard let code = KeyNames.keyCode(for: keyName),
              let wmAction = PanelessConfig.parseAction(action) else { return nil }
        return KeyBinding(modifiers: modifierFlags, keyCode: code, action: wmAction)
    }
}

// MARK: - Compact read-only row (displayed in the list)

private struct BindingRow: View {
    let binding: EditableBinding
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text(binding.shortcutDisplay)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.caption)

            Text(ActionLabels.label(for: binding.action))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { onDelete() } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Edit sheet (opened on row click or add)

private struct BindingEditor: View {
    @Binding var binding: EditableBinding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Binding")
                .font(.headline)

            // Modifiers
            HStack(spacing: 6) {
                Text("Modifiers")
                    .frame(width: 70, alignment: .trailing)
                ModifierPill(label: "Opt", isOn: $binding.alt)
                ModifierPill(label: "Shift", isOn: $binding.shift)
                ModifierPill(label: "Cmd", isOn: $binding.cmd)
                ModifierPill(label: "Ctrl", isOn: $binding.ctrl)
            }

            // Key
            HStack {
                Text("Key")
                    .frame(width: 70, alignment: .trailing)
                Picker("", selection: $binding.keyName) {
                    ForEach(KeyNames.allKeyNames, id: \.self) { name in
                        Text(KeybindingsTab.keyDisplayName(name)).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                Spacer()
            }

            // Action
            HStack {
                Text("Action")
                    .frame(width: 70, alignment: .trailing)
                Picker("", selection: $binding.action) {
                    ForEach(ActionLabels.choices(including: binding.action), id: \.value) { a in
                        Text(a.label).tag(a.value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260)
                Spacer()
            }

            // Preview
            HStack {
                Text("Result")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(binding.shortcutDisplay + "  ->  " + (ActionLabels.label(for: binding.action)))
                    .fontWeight(.medium)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct ModifierPill: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isOn ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15))
                .foregroundColor(isOn ? .white : .secondary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keybindings Tab

struct KeybindingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var editingIndex: Int? = nil
    @State private var isAddingNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keybindings")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.bindings.count) bindings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Text("Workspace bindings (Alt+1-9, Alt+Shift+1-9) are always active and not shown here. Click a row to edit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List {
                ForEach(Array(viewModel.bindings.enumerated()), id: \.element.id) { index, binding in
                    BindingRow(binding: binding) {
                        viewModel.bindings.remove(at: index)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingIndex = index }
                }
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button {
                    viewModel.bindings.append(EditableBinding(alt: true, shift: true))
                    editingIndex = viewModel.bindings.count - 1
                } label: {
                    Label("Add Binding", systemImage: "plus")
                }
                .padding(8)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingIndex != nil },
            set: { if !$0 { editingIndex = nil } }
        )) {
            if let idx = editingIndex, idx < viewModel.bindings.count {
                BindingEditor(binding: $viewModel.bindings[idx])
            }
        }
    }

    static func keyDisplayName(_ name: String) -> String {
        let display: [String: String] = [
            "return": "Return", "space": "Space", "tab": "Tab",
            "escape": "Esc", "delete": "Delete",
            "up": "Up", "down": "Down", "left": "Left", "right": "Right",
            "minus": "-", "equal": "=", "leftbracket": "[", "rightbracket": "]",
            "semicolon": ";", "quote": "'", "comma": ",", "period": ".",
            "slash": "/", "backslash": "\\", "grave": "`", "caps_lock": "CapsLk",
        ]
        return display[name] ?? name.uppercased()
    }
}
