import Cocoa
import SwiftUI

// MARK: - Root SwiftUI View

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        TabView {
            GeneralTab(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gear") }

            AppearanceTab(viewModel: viewModel)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Settings Window

class SettingsWindow: NSWindow, NSWindowDelegate {

    let viewModel = SettingsViewModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Paneless Settings"
        isReleasedWhenClosed = false
        delegate = self
        center()

        let hostingView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        contentView = hostingView
    }

    func showWindow() {
        viewModel.loadFromConfig()
        NSApp.setActivationPolicy(.regular)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
