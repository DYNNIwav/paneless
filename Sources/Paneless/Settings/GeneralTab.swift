import SwiftUI

private struct SettingDescription: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct GeneralTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $viewModel.tilingMode) {
                    Text("Hyprland").tag("hyprland")
                    Text("Niri (scrolling columns)").tag("niri")
                }
                .pickerStyle(.segmented)
                SettingDescription(text: viewModel.tilingMode == "hyprland"
                    ? "Master-stack layout with split ratios, similar to Hyprland on Linux."
                    : "Horizontally scrolling columns, similar to Niri/PaperWM.")

                if viewModel.tilingMode == "niri" {
                    HStack {
                        Text("Column width")
                        Slider(value: $viewModel.niriColumnWidth, in: 0.1...3.0, step: 0.1)
                        Text("\(Int(viewModel.niriColumnWidth * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    SettingDescription(text: "Width of each column as a percentage of the screen. 100% = one column fills the screen.")
                }

                HStack {
                    Stepper("Inner gap", value: $viewModel.innerGap, in: 0...64, step: 1)
                    Text("\(Int(viewModel.innerGap)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SettingDescription(text: "Space between adjacent windows.")

                HStack {
                    Stepper("Outer gap", value: $viewModel.outerGap, in: 0...64, step: 1)
                    Text("\(Int(viewModel.outerGap)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SettingDescription(text: "Space between windows and screen edges.")

                HStack {
                    Stepper("Single window padding", value: $viewModel.singleWindowPadding, in: 0...200, step: 4)
                    Text("\(Int(viewModel.singleWindowPadding)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SettingDescription(text: "Extra padding when only one window is tiled. 0 = fill the entire screen.")
            } header: {
                Text("Tiling")
            }

            Section {
                Toggle("GPU animations", isOn: $viewModel.animations)
                SettingDescription(text: "Smooth window transitions using GPU-composited transforms. Disable for instant snapping.")

                Toggle("Native macOS compositor", isOn: $viewModel.nativeAnimation)
                SettingDescription(text: "Use the built-in macOS window tiling animation instead of GPU transforms. Incompatible with gaps.")
            } header: {
                Text("Animation")
            }

            Section {
                Toggle("Focus follows mouse", isOn: $viewModel.focusFollowsMouse)
                SettingDescription(text: "Automatically focus the window under your mouse cursor.")

                Toggle("Focus follows app", isOn: $viewModel.focusFollowsApp)
                SettingDescription(text: "Auto-switch workspace when an app on another workspace activates (e.g. clicking a notification).")

                Toggle("Auto-float dialogs", isOn: $viewModel.autoFloatDialogs)
                SettingDescription(text: "Automatically float small windows like dialogs and popups instead of tiling them.")
            } header: {
                Text("Focus")
            }

            Section {
                Picker("Hyperkey", selection: $viewModel.hyperkeyOption) {
                    Text("Disabled").tag("disabled")
                    Text("Caps Lock").tag("caps_lock")
                    Text("F18").tag("f18")
                    Text("Grave (`)").tag("grave")
                }
                SettingDescription(text: "Remap a single key to act as Ctrl+Opt+Cmd+Shift when held. Useful for dedicated window management shortcuts without conflicts.")

                Toggle("Force ProMotion (120 Hz)", isOn: $viewModel.forceProMotion)
                SettingDescription(text: "Prevent macOS from dropping to 60 Hz when idle. Only relevant on ProMotion displays (MacBook Pro 14\"/16\"). Uses slightly more battery.")
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
