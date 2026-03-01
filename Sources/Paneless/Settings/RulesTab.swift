import SwiftUI

private struct SettingDescription: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Editable App List

private struct AppListSection: View {
    let title: String
    let description: String
    @Binding var apps: [String]
    @State private var newApp = ""

    var body: some View {
        Section {
            SettingDescription(text: description)

            ForEach(apps, id: \.self) { app in
                HStack {
                    Text(app)
                    Spacer()
                    Button {
                        apps.removeAll { $0 == app }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("App name", text: $newApp)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addApp() }
                Button("Add") { addApp() }
                    .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(title)
        }
    }

    private func addApp() {
        let trimmed = newApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !apps.contains(trimmed) else { return }
        apps.append(trimmed)
        newApp = ""
    }
}

// MARK: - App Layout Rule

struct AppLayoutRule: Identifiable {
    let id = UUID()
    var app: String
    var direction: String
}

// MARK: - Rules Tab

struct RulesTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var newLayoutApp = ""
    @State private var newLayoutDirection = "left"

    var body: some View {
        Form {
            AppListSection(
                title: "Float",
                description: "These apps will float above tiled windows instead of being tiled.",
                apps: $viewModel.floatApps
            )

            AppListSection(
                title: "Exclude",
                description: "These apps will be completely ignored by Paneless.",
                apps: $viewModel.excludeApps
            )

            AppListSection(
                title: "Sticky",
                description: "These apps stay visible on all workspaces.",
                apps: $viewModel.stickyApps
            )

            AppListSection(
                title: "Swallow",
                description: "Terminal apps that support window swallowing. When a terminal launches a GUI app, the GUI replaces the terminal in the tiling layout.",
                apps: $viewModel.swallowApps
            )

            Section {
                SettingDescription(text: "Force an app to always tile on a specific side. Useful for keeping your editor on the left and terminal on the right.")

                ForEach(Array(viewModel.appLayoutRules.keys.sorted()), id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Text(viewModel.appLayoutRules[app] ?? "")
                            .foregroundStyle(.secondary)
                        Button {
                            viewModel.appLayoutRules.removeValue(forKey: app)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("App name", text: $newLayoutApp)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $newLayoutDirection) {
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                    .frame(width: 100)
                    Button("Add") { addLayoutRule() }
                        .disabled(newLayoutApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Layout Rules")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func addLayoutRule() {
        let trimmed = newLayoutApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.appLayoutRules[trimmed] = newLayoutDirection
        newLayoutApp = ""
    }
}
