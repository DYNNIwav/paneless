import Cocoa

// MARK: - Screen Helpers

extension NSScreen {
    /// Safe accessor that never force-unwraps. Falls back to a dummy frame on headless systems.
    static var safeMain: NSScreen {
        NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}

// MARK: - CGS Private API Types

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

// MARK: - Window Tracking

struct TrackedWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    var isFloating: Bool = false
    var frame: CGRect = .zero

    // Window swallowing: terminal window that was replaced by this GUI app
    var swallowedFrom: CGWindowID?
    // Window swallowing: GUI app that replaced this terminal window
    var swallowedBy: CGWindowID?
}

// MARK: - Niri Column

struct NiriColumn {
    var windows: [CGWindowID]
    var widthOverride: CGFloat?
    var focusedIndex: Int = 0

    var focusedWindow: CGWindowID? {
        guard !windows.isEmpty else { return nil }
        return windows[clampedFocusedIndex]
    }

    var clampedFocusedIndex: Int {
        max(0, min(focusedIndex, windows.count - 1))
    }
}

// MARK: - Enums

enum Direction: String, CaseIterable {
    case left, down, up, right
}

enum WMAction {
    case focusDirection(Direction)
    case focusNext
    case focusPrev
    case swapWithMaster
    case toggleFloat
    case toggleFullscreen
    case closeFocused
    case focusMonitor(Direction)
    case moveToMonitor(Direction)
    case positionLeft
    case positionRight
    case positionUp
    case positionDown
    case positionFill
    case positionCenter
    case cycleLayout
    case increaseGap
    case decreaseGap
    case growFocused
    case shrinkFocused
    case rotateNext
    case rotatePrev
    case retile
    case reloadConfig
    case switchWorkspace(Int)
    case moveToWorkspace(Int)
    case minimizeToWorkspace
    case setMark(String)
    case jumpToMark(String)
    case niriConsume
    case niriExpel
}

struct TilingRegion {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Keybinding Types

struct KeyBinding {
    let modifiers: CGEventFlags
    let keyCode: UInt16
    let action: WMAction
}

// MARK: - Border Configuration

struct BorderConfig {
    var enabled: Bool = false
    var width: CGFloat = 2
    var activeColor: NSColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0) // #66ccff
    var inactiveColor: NSColor = NSColor(red: 0.27, green: 0.27, blue: 0.27, alpha: 1.0) // #444444
    var radius: CGFloat = 10
}

// MARK: - Key Name Resolution

enum KeyNames {
    private static let nameToCode: [String: UInt16] = [
        // Letters
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        // Numbers
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        // Special keys
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "escape": 53, "esc": 53, "delete": 51, "backspace": 51,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        // Caps Lock
        "caps_lock": 57, "capslock": 57,
        // Punctuation
        "minus": 27, "equal": 24, "leftbracket": 33, "rightbracket": 30,
        "semicolon": 41, "quote": 39, "comma": 43, "period": 47,
        "slash": 44, "backslash": 42, "grave": 50,
    ]

    /// All unique key names sorted alphabetically (excludes aliases like "enter", "esc", "capslock", "backspace")
    static let allKeyNames: [String] = {
        let aliases: Set<String> = ["enter", "esc", "capslock", "backspace"]
        return Array(Set(nameToCode.keys).subtracting(aliases)).sorted()
    }()

    static func keyCode(for name: String) -> UInt16? {
        return nameToCode[name.lowercased()]
    }

    static func keyName(for code: UInt16) -> String? {
        for (name, c) in nameToCode where c == code {
            return name
        }
        return nil
    }

    static func modifierString(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && flags.contains(.maskCommand) && flags.contains(.maskShift) {
            return "hyper"
        }
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("alt") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        return parts.joined(separator: "+")
    }

    static func parseModifiers(_ modString: String) -> CGEventFlags {
        var flags = CGEventFlags()
        let parts = modString.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            switch part {
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "cmd", "command", "super": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "hyper":
                flags.insert(.maskControl)
                flags.insert(.maskAlternate)
                flags.insert(.maskCommand)
                flags.insert(.maskShift)
            default: break
            }
        }
        return flags
    }
}

// MARK: - Hex Color Parsing

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var hexStr = hex.trimmingCharacters(in: .whitespaces)
        if hexStr.hasPrefix("#") { hexStr = String(hexStr.dropFirst()) }
        if hexStr.hasPrefix("0x") { hexStr = String(hexStr.dropFirst(2)) }

        guard hexStr.count == 6, let value = UInt64(hexStr, radix: 16) else { return nil }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    func toHex() -> String {
        let c = usingColorSpace(.sRGB) ?? self
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
