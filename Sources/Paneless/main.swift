import Cocoa

// MARK: - CLI Mode

if CommandLine.arguments.count >= 2 {
    let arg = CommandLine.arguments[1]

    switch arg {
    case "--focus-workspace":
        if CommandLine.arguments.count >= 3, let n = Int(CommandLine.arguments[2]), n >= 1, n <= 9 {
            // CLI workspace switch: start the app briefly to perform the switch
            let delegate = PanelessAppDelegate()
            let app = NSApplication.shared
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            WindowManager.shared.handleAction(.switchWorkspace(n))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } else {
            fputs("Usage: paneless --focus-workspace N  (N = 1-9)\n", stderr)
            exit(1)
        }
        exit(0)

    case "--focus-space":
        // Backward compatibility — deprecated
        fputs("WARNING: --focus-space is deprecated, use --focus-workspace instead\n", stderr)
        if CommandLine.arguments.count >= 3, let n = Int(CommandLine.arguments[2]), n >= 1, n <= 9 {
            let delegate = PanelessAppDelegate()
            let app = NSApplication.shared
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            WindowManager.shared.handleAction(.switchWorkspace(n))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } else {
            fputs("Usage: paneless --focus-workspace N  (N = 1-9)\n", stderr)
            exit(1)
        }
        exit(0)

    case "--list-workspaces", "--list-spaces":
        if arg == "--list-spaces" {
            fputs("WARNING: --list-spaces is deprecated, use --list-workspaces instead\n", stderr)
        }
        guard let listing = WorkspaceListing.ask() else {
            fputs("Paneless is not running\n", stderr)
            exit(1)
        }
        print(listing.text())
        exit(0)

    case "--help", "-h":
        print("""
        Paneless - Tiling Window Manager for macOS

        Usage:
          paneless                             Start as daemon (menu bar app)
          paneless --focus-workspace N         Switch to workspace N (1-9)
          paneless --list-workspaces           List workspaces and their windows
          paneless --help                      Show this help

        Default Hotkeys:
          Alt+1-9              Switch to workspace N
          Alt+Shift+1-9        Move window to workspace N
          Alt+Shift+H/L        Focus prev/next window
          Alt+Shift+J/K        Rotate window positions
          Alt+Shift+Enter      Swap with master
          Alt+Shift+Space      Cycle layout
          Alt+Shift+T          Toggle float
          Alt+Shift+F          Toggle fullscreen
          Alt+Shift+Q          Close window
          Alt+Shift+,/.        Focus monitor left/right

        Hyperkey:
          Set "hyperkey = f18" in [layout] (remap Caps Lock to F18 via hidutil).
          Acts as Ctrl+Opt+Cmd+Shift when held, works globally for all apps.
          Bind Paneless actions with "hyper, key = action" in [bindings].

        Config: ~/.config/paneless/config

        Requires:
          - Accessibility: System Settings > Privacy & Security > Accessibility
          - Input Monitoring: System Settings > Privacy & Security > Input Monitoring
        """)
        exit(0)

    default:
        fputs("Unknown argument: \(arg). Use --help for usage.\n", stderr)
        exit(1)
    }
}

// MARK: - Daemon Mode

let delegate = PanelessAppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
