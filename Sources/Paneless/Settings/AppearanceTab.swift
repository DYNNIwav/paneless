import SwiftUI

private struct SettingDescription: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct AppearanceTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Show border", isOn: $viewModel.borderEnabled)
                SettingDescription(text: "Draw a colored outline around the focused window, similar to Hyprland on Linux.")

                if viewModel.borderEnabled {
                    HStack {
                        Stepper("Width", value: $viewModel.borderWidth, in: 1...10, step: 1)
                        Text("\(Int(viewModel.borderWidth)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Stepper("Radius", value: $viewModel.borderRadius, in: 0...30, step: 1)
                        Text("\(Int(viewModel.borderRadius)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    SettingDescription(text: "Corner rounding of the border. Match your window corner radius for a clean look.")

                    ColorPicker("Active color", selection: $viewModel.borderActiveColor, supportsOpacity: false)
                    ColorPicker("Inactive color", selection: $viewModel.borderInactiveColor, supportsOpacity: false)
                }
            } header: {
                Text("Window Border")
            }

            Section {
                HStack {
                    Text("Dim unfocused windows")
                    Slider(value: $viewModel.dimUnfocused, in: 0...0.5, step: 0.01)
                    Text(viewModel.dimUnfocused == 0 ? "Off" : String(format: "%.0f%%", viewModel.dimUnfocused * 100))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                SettingDescription(text: "Reduce brightness of unfocused windows using the GPU compositor. Helps visually identify the active window.")
            } header: {
                Text("Dimming")
            }

            Section {
                Toggle("Custom active color", isOn: $viewModel.useCustomMenubarActive)
                if viewModel.useCustomMenubarActive {
                    ColorPicker("Active", selection: Binding(
                        get: { viewModel.menubarActiveColor ?? .blue },
                        set: { viewModel.menubarActiveColor = $0 }
                    ), supportsOpacity: false)
                }
                SettingDescription(text: "Color for the active workspace number in the menu bar. Default is Catppuccin blue.")

                Toggle("Custom inactive color", isOn: $viewModel.useCustomMenubarInactive)
                if viewModel.useCustomMenubarInactive {
                    ColorPicker("Inactive", selection: Binding(
                        get: { viewModel.menubarInactiveColor ?? .gray },
                        set: { viewModel.menubarInactiveColor = $0 }
                    ), supportsOpacity: false)
                }
                SettingDescription(text: "Color for inactive workspace numbers in the menu bar. Default is Catppuccin overlay.")
            } header: {
                Text("Menu Bar Colors")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
