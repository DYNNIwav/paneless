import SwiftUI

private struct SettingDescription: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct WorkspacesTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var newRuleApp = ""
    @State private var newRuleWorkspace = 1

    var body: some View {
        Form {
            Section {
                SettingDescription(text: "Give workspaces custom names that show in the menu bar and workspace switcher.")

                ForEach(1...9, id: \.self) { num in
                    HStack {
                        Text("\(num)")
                            .monospacedDigit()
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(.secondary)
                        TextField("Unnamed", text: workspaceNameBinding(for: num))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Text("Workspace Names")
            }

            Section {
                SettingDescription(text: "Automatically move an app to a specific workspace when it opens. For example, always send Slack to workspace 3.")

                ForEach(Array(viewModel.appWorkspaceRules.keys.sorted()), id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Text("Workspace \(viewModel.appWorkspaceRules[app] ?? 1)")
                            .foregroundStyle(.secondary)
                        Button {
                            viewModel.appWorkspaceRules.removeValue(forKey: app)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("App name", text: $newRuleApp)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $newRuleWorkspace) {
                        ForEach(1...9, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .frame(width: 60)
                    Button("Add") { addWorkspaceRule() }
                        .disabled(newRuleApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("App Workspace Rules")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func workspaceNameBinding(for num: Int) -> Binding<String> {
        Binding(
            get: { viewModel.workspaceNames[num] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    viewModel.workspaceNames.removeValue(forKey: num)
                } else {
                    viewModel.workspaceNames[num] = trimmed
                }
            }
        )
    }

    private func addWorkspaceRule() {
        let trimmed = newRuleApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.appWorkspaceRules[trimmed] = newRuleWorkspace
        newRuleApp = ""
    }
}
