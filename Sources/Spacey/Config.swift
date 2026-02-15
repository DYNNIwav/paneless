import Cocoa

struct SpaceyConfig {
    var innerGap: CGFloat = 8
    var outerGap: CGFloat = 8
    var sketchybarHeight: CGFloat = 0
    var spaceSwitchModifier: String = "alt"

    // Auto-float dialogs and small windows
    var autoFloatDialogs: Bool = true

    // Single window padding (0 = fill entire region)
    var singleWindowPadding: CGFloat = 0

    // Focus follows mouse
    var focusFollowsMouse: Bool = false

    // Dim unfocused windows (0.0 = no dim, 0.3 = moderate dim)
    var dimUnfocused: CGFloat = 0

    // Use native macOS compositor tiling (no gaps support)
    var nativeAnimation: Bool = false

    // Force ProMotion to stay at 120Hz (keeps a CVDisplayLink running)
    var forceProMotion: Bool = false

    // Borders
    var border: BorderConfig = BorderConfig()

    // App rules
    var floatApps: Set<String> = [
        "Finder", "System Settings", "Calculator",
        "Archive Utility", "System Preferences",
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.calculator",
        "com.apple.archiveutility"
    ]
    var excludeApps: Set<String> = []

    // Per-app layout rules (e.g. "Arc" -> "left", "Ghostty" -> "right")
    var appLayoutRules: [String: String] = [:]

    // Per-app workspace assignment (e.g. "Slack" -> 3)
    var appWorkspaceRules: [String: Int] = [:]

    // Sticky apps (visible on ALL workspaces)
    var stickyApps: Set<String> = []

    // Keybindings (populated from config or defaults)
    var keyBindings: [KeyBinding] = []

    // MARK: - Default Keybindings

    static func defaultKeyBindings() -> [KeyBinding] {
        let altShift: CGEventFlags = [.maskAlternate, .maskShift]
        var bindings: [KeyBinding] = []

        // H/L: cycle focus through tiled windows
        if let h = KeyNames.keyCode(for: "h") { bindings.append(KeyBinding(modifiers: altShift, keyCode: h, action: .focusPrev)) }
        if let l = KeyNames.keyCode(for: "l") { bindings.append(KeyBinding(modifiers: altShift, keyCode: l, action: .focusNext)) }

        // J/K: rotate window positions (swap which window is where)
        if let j = KeyNames.keyCode(for: "j") { bindings.append(KeyBinding(modifiers: altShift, keyCode: j, action: .rotateNext)) }
        if let k = KeyNames.keyCode(for: "k") { bindings.append(KeyBinding(modifiers: altShift, keyCode: k, action: .rotatePrev)) }

        // Enter: swap with master
        if let ret = KeyNames.keyCode(for: "return") { bindings.append(KeyBinding(modifiers: altShift, keyCode: ret, action: .swapWithMaster)) }

        // Space: cycle layout
        if let space = KeyNames.keyCode(for: "space") { bindings.append(KeyBinding(modifiers: altShift, keyCode: space, action: .cycleLayout)) }

        // T: toggle float
        if let t = KeyNames.keyCode(for: "t") { bindings.append(KeyBinding(modifiers: altShift, keyCode: t, action: .toggleFloat)) }

        // F: toggle fullscreen
        if let f = KeyNames.keyCode(for: "f") { bindings.append(KeyBinding(modifiers: altShift, keyCode: f, action: .toggleFullscreen)) }

        // Q: close focused
        if let q = KeyNames.keyCode(for: "q") { bindings.append(KeyBinding(modifiers: altShift, keyCode: q, action: .closeFocused)) }

        // Monitor focus: Alt+Shift+comma/period
        if let comma = KeyNames.keyCode(for: "comma") { bindings.append(KeyBinding(modifiers: altShift, keyCode: comma, action: .focusMonitor(.left))) }
        if let period = KeyNames.keyCode(for: "period") { bindings.append(KeyBinding(modifiers: altShift, keyCode: period, action: .focusMonitor(.right))) }

        // Gap resize: Alt+Shift+Equal/Minus
        if let eq = KeyNames.keyCode(for: "equal") { bindings.append(KeyBinding(modifiers: altShift, keyCode: eq, action: .increaseGap)) }
        if let minus = KeyNames.keyCode(for: "minus") { bindings.append(KeyBinding(modifiers: altShift, keyCode: minus, action: .decreaseGap)) }

        // Grow/shrink focused window: Alt+Shift+]/[
        if let rb = KeyNames.keyCode(for: "rightbracket") { bindings.append(KeyBinding(modifiers: altShift, keyCode: rb, action: .growFocused)) }
        if let lb = KeyNames.keyCode(for: "leftbracket") { bindings.append(KeyBinding(modifiers: altShift, keyCode: lb, action: .shrinkFocused)) }

        // Position: Cmd+Shift+HJKL — swap/move focused window
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        if let h = KeyNames.keyCode(for: "h") { bindings.append(KeyBinding(modifiers: cmdShift, keyCode: h, action: .positionLeft)) }
        if let l = KeyNames.keyCode(for: "l") { bindings.append(KeyBinding(modifiers: cmdShift, keyCode: l, action: .positionRight)) }
        if let k = KeyNames.keyCode(for: "k") { bindings.append(KeyBinding(modifiers: cmdShift, keyCode: k, action: .positionUp)) }
        if let j = KeyNames.keyCode(for: "j") { bindings.append(KeyBinding(modifiers: cmdShift, keyCode: j, action: .positionDown)) }

        // Position: Cmd+Shift+F — fill tiling region
        if let f = KeyNames.keyCode(for: "f") { bindings.append(KeyBinding(modifiers: cmdShift, keyCode: f, action: .positionFill)) }

        // Virtual workspace switching: Alt+1-9
        let alt: CGEventFlags = [.maskAlternate]
        for n in 1...9 {
            if let code = KeyNames.keyCode(for: "\(n)") {
                bindings.append(KeyBinding(modifiers: alt, keyCode: code, action: .switchWorkspace(n)))
            }
        }

        // Move window to workspace: Alt+Shift+1-9
        for n in 1...9 {
            if let code = KeyNames.keyCode(for: "\(n)") {
                bindings.append(KeyBinding(modifiers: altShift, keyCode: code, action: .moveToWorkspace(n)))
            }
        }

        return bindings
    }

    // MARK: - Load

    static func load() -> SpaceyConfig {
        var config = SpaceyConfig()

        let configPath = NSString("~/.config/spacey/config").expandingTildeInPath
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            spaceyLog("No config file at \(configPath), using defaults")
            config.keyBindings = defaultKeyBindings()
            return config
        }

        var currentSection = ""
        var customBindings: [KeyBinding] = []
        var hasCustomBindings = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch currentSection {
            case "layout":
                switch key {
                case "inner_gap": config.innerGap = CGFloat(Double(value) ?? 8)
                case "outer_gap": config.outerGap = CGFloat(Double(value) ?? 8)
                case "sketchybar_height": config.sketchybarHeight = CGFloat(Double(value) ?? 0)
                case "space_switch_modifier": config.spaceSwitchModifier = value.lowercased()
                case "auto_float_dialogs": config.autoFloatDialogs = value != "false" && value != "0"
                case "single_window_padding": config.singleWindowPadding = CGFloat(Double(value) ?? 0)
                case "focus_follows_mouse": config.focusFollowsMouse = value == "true" || value == "1"
                case "dim_unfocused": config.dimUnfocused = CGFloat(Double(value) ?? 0)
                case "native_animation": config.nativeAnimation = value == "true" || value == "1"
                case "force_promotion": config.forceProMotion = value == "true" || value == "1"
                default: break
                }

            case "border":
                switch key {
                case "enabled": config.border.enabled = value != "false" && value != "0"
                case "width": config.border.width = CGFloat(Double(value) ?? 2)
                case "active_color":
                    if let color = NSColor.fromHex(value) { config.border.activeColor = color }
                case "inactive_color":
                    if let color = NSColor.fromHex(value) { config.border.inactiveColor = color }
                case "radius": config.border.radius = CGFloat(Double(value) ?? 10)
                default: break
                }

            case "rules":
                let apps = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                switch key {
                case "float": config.floatApps = Set(apps)
                case "exclude": config.excludeApps = Set(apps)
                case "sticky": config.stickyApps = Set(apps)
                default: break
                }

            case "app_rules":
                // e.g. "Arc = left", "Ghostty = right", "Slack = workspace 3"
                let lowerValue = value.lowercased()
                if lowerValue.hasPrefix("workspace "),
                   let n = Int(lowerValue.dropFirst("workspace ".count)),
                   n >= 1, n <= 9 {
                    config.appWorkspaceRules[key] = n
                } else {
                    config.appLayoutRules[key] = lowerValue
                }

            case "bindings":
                hasCustomBindings = true
                if let binding = parseBinding(key: key, value: value) {
                    customBindings.append(binding)
                }

            default: break
            }
        }

        config.keyBindings = hasCustomBindings ? customBindings : defaultKeyBindings()

        // Always add workspace bindings (Alt+1-9 switch, Alt+Shift+1-9 move)
        // even with custom bindings — these are fundamental to virtual workspaces
        let existingKeyCodes = Set(config.keyBindings.map { "\($0.modifiers.rawValue)-\($0.keyCode)" })
        for binding in workspaceKeyBindings() {
            let key = "\(binding.modifiers.rawValue)-\(binding.keyCode)"
            if !existingKeyCodes.contains(key) {
                config.keyBindings.append(binding)
            }
        }

        // Always add bundle IDs for reliable matching on localized systems.
        config.floatApps.formUnion(resolveBundleIDs(config.floatApps))
        config.excludeApps.formUnion(resolveBundleIDs(config.excludeApps))
        config.stickyApps.formUnion(resolveBundleIDs(config.stickyApps))

        spaceyLog("Config loaded from \(configPath)")
        return config
    }

    /// Map known app names to their bundle IDs for locale-independent matching.
    private static func resolveBundleIDs(_ apps: Set<String>) -> Set<String> {
        let knownApps: [String: String] = [
            "finder": "com.apple.finder",
            "system settings": "com.apple.systempreferences",
            "system preferences": "com.apple.systempreferences",
            "calculator": "com.apple.calculator",
            "archive utility": "com.apple.archiveutility",
            "activity monitor": "com.apple.ActivityMonitor",
            "disk utility": "com.apple.DiskUtility",
            "font book": "com.apple.FontBook",
            "keychain access": "com.apple.keychainaccess",
            "screenshot": "com.apple.Screenshot",
            "preview": "com.apple.Preview",
            "sketchybar": "com.felixkratz.sketchybar",
        ]
        var result = Set<String>()
        for app in apps {
            if let bid = knownApps[app.lowercased()] {
                result.insert(bid)
            }
        }
        return result
    }

    /// Workspace keybindings — always added, even with custom [bindings] section
    private static func workspaceKeyBindings() -> [KeyBinding] {
        var bindings: [KeyBinding] = []
        let alt: CGEventFlags = [.maskAlternate]
        let altShift: CGEventFlags = [.maskAlternate, .maskShift]
        for n in 1...9 {
            if let code = KeyNames.keyCode(for: "\(n)") {
                bindings.append(KeyBinding(modifiers: alt, keyCode: code, action: .switchWorkspace(n)))
                bindings.append(KeyBinding(modifiers: altShift, keyCode: code, action: .moveToWorkspace(n)))
            }
        }
        return bindings
    }

    // MARK: - Binding Parser

    private static func parseBinding(key: String, value: String) -> KeyBinding? {
        let keyParts = key.split(separator: ",", maxSplits: 1)
        guard keyParts.count == 2 else { return nil }

        let modString = keyParts[0].trimmingCharacters(in: .whitespaces)
        let keyName = keyParts[1].trimmingCharacters(in: .whitespaces)

        let modifiers = KeyNames.parseModifiers(modString)
        guard let keyCode = KeyNames.keyCode(for: keyName) else {
            spaceyLog("Unknown key name in binding: '\(keyName)'")
            return nil
        }

        guard let action = parseAction(value) else {
            spaceyLog("Unknown action in binding: '\(value)'")
            return nil
        }

        return KeyBinding(modifiers: modifiers, keyCode: keyCode, action: action)
    }

    private static func parseAction(_ str: String) -> WMAction? {
        let parts = str.split(separator: " ", maxSplits: 1)
        let action = parts[0].lowercased()
        let arg = parts.count > 1 ? String(parts[1]) : nil

        switch action {
        case "focus_left": return .focusDirection(.left)
        case "focus_down": return .focusDirection(.down)
        case "focus_up": return .focusDirection(.up)
        case "focus_right": return .focusDirection(.right)
        case "swap_master": return .swapWithMaster
        case "toggle_float": return .toggleFloat
        case "toggle_fullscreen": return .toggleFullscreen
        case "close": return .closeFocused
        case "retile": return .retile
        case "reload_config": return .reloadConfig
        case "focus_monitor":
            if let dir = Direction(rawValue: arg ?? "right") { return .focusMonitor(dir) }
            return .focusMonitor(.right)
        case "move_to_monitor":
            if let dir = Direction(rawValue: arg ?? "right") { return .moveToMonitor(dir) }
            return .moveToMonitor(.right)
        case "position_left": return .positionLeft
        case "position_right": return .positionRight
        case "position_up": return .positionUp
        case "position_down": return .positionDown
        case "position_fill": return .positionFill
        case "position_center": return .positionCenter
        case "cycle_layout": return .cycleLayout
        case "increase_gap": return .increaseGap
        case "decrease_gap": return .decreaseGap
        case "grow_focused": return .growFocused
        case "shrink_focused": return .shrinkFocused
        case "rotate_next": return .rotateNext
        case "rotate_prev": return .rotatePrev
        case "focus_next": return .focusNext
        case "focus_prev": return .focusPrev
        case "switch_workspace":
            if let n = arg.flatMap({ Int($0) }), n >= 1, n <= 9 { return .switchWorkspace(n) }
            return nil
        case "move_to_workspace":
            if let n = arg.flatMap({ Int($0) }), n >= 1, n <= 9 { return .moveToWorkspace(n) }
            return nil
        default: return nil
        }
    }
}
