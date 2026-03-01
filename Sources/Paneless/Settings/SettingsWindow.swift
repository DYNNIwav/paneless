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

            RulesTab(viewModel: viewModel)
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }

            WorkspacesTab(viewModel: viewModel)
                .tabItem { Label("Workspaces", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - Settings Window

class SettingsWindow: NSWindow, NSWindowDelegate {

    let viewModel = SettingsViewModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
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
