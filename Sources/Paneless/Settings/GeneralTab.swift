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

                    HStack {
                        Stepper("Narrowest column", value: $viewModel.niriMinColumnWidth, in: 0...2000, step: 40)
                        Text(viewModel.niriMinColumnWidth == 0 ? "off" : "\(Int(viewModel.niriMinColumnWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                    SettingDescription(text: "The width above is a percentage, so it means a roomy column on a large display and a cramped one on a laptop. A column narrower than this steps up to the next whole fraction instead: a screen too narrow for thirds uses halves. Set to 0 to let the percentage stand whatever the screen.")

                    Picker("Windows sharing a column", selection: $viewModel.niriColumnStack) {
                        Text("Automatic").tag("auto")
                        Text("Stacked").tag("vertical")
                        Text("Side by side").tag("horizontal")
                    }
                    SettingDescription(text: viewModel.niriColumnStack == "auto"
                        ? "Stacks them until a pane would get too short to work in, and only then splits the column across."
                        : (viewModel.niriColumnStack == "vertical"
                            ? "Always one above the other. Best in wide columns; in narrow ones it makes letterbox strips."
                            : "Always beside each other. Best in wide columns; in narrow ones it makes thin slivers."))

                    Toggle("Fill the screen when there is room", isOn: $viewModel.niriFillScreen)
                    SettingDescription(text: "One window takes the whole screen, two take half each, three a third, and only then does the strip start to scroll.")
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
                Toggle("Animate window movement", isOn: $viewModel.animations)
                SettingDescription(text: "Smooth window transitions using GPU-composited transforms. Disable for instant snapping.")

                Toggle("Native macOS compositor", isOn: $viewModel.nativeAnimation)

                Toggle("Resize in one step", isOn: $viewModel.sizeOnce)
                SettingDescription(text: "Take the final size at once and animate only the movement. A resize costs up to 50ms on a heavy app against 2ms for a move, so this keeps the frame rate up at the cost of the size snapping.")

                Picker("Who animates a move", selection: $viewModel.appDrivenAnimation) {
                    Text("Paneless").tag("off")
                    Text("The app, when only moving").tag("moves")
                    Text("The app, always").tag("always")
                }
                SettingDescription(text: viewModel.appDrivenAnimation == "off"
                    ? "Paneless writes every frame itself. Even pacing, but each frame is a separate message to each app, and one busy app delays the others."
                    : (viewModel.appDrivenAnimation == "moves"
                        ? "A move is handed to the app, which animates it at around 110fps from a single message. Anything that also resizes stays with Paneless, since apps snap size rather than ease it."
                        : "Everything is handed to the app. Smoothest for movement, but sizes jump instead of growing."))
                SettingDescription(text: "Hand each app its destination once and let it run its own animation. Fewer messages and no cost to Paneless, but the pacing is less even and the curve is the system's rather than ours.")
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
