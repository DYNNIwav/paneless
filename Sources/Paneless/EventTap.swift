import Cocoa

// MARK: - EventTap

class EventTap {
    static var shared: EventTap?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var heartbeatTimer: Timer?

    /// Whether the event tap was successfully created (Input Monitoring granted)
    var isActive: Bool { eventTap != nil }

    var actionHandler: ((WMAction) -> Void)?
    var keyBindings: [KeyBinding] = []

    // Hyperkey: which key acts as hyper (nil = disabled)
    var hyperkeyCode: UInt16?
    private var hyperkeyDown = false
    private var hyperkeyUsed = false

    func start() {
        EventTap.shared = self

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            panelessLog("Failed to create event tap. Grant Input Monitoring in System Settings > Privacy & Security.")
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Heartbeat: verify tap is still alive every 5 seconds
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }

        panelessLog("Event tap started")
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        EventTap.shared = nil
    }

    func reEnable() {
        hyperkeyDown = false
        hyperkeyUsed = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            panelessLog("Event tap re-enabled")
        }
    }

    // Caps Lock hyperkey: toggle state on each flagsChanged with keycode 57.
    // Can't use maskAlphaShift since suppressing the event desyncs the flag.
    func handleFlagsChanged(_ keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let hk = hyperkeyCode, hk == 57, keyCode == 57 else { return false }

        if !hyperkeyDown {
            hyperkeyDown = true
            hyperkeyUsed = false
        } else {
            hyperkeyDown = false
        }
        return true  // suppress to prevent caps lock from toggling
    }

    // Non-modifier hyperkeys (grave, F-keys, etc): suppress the trigger key itself
    func handleHyperkeyDown(_ keyCode: UInt16) -> Bool {
        guard let hk = hyperkeyCode, hk != 57, keyCode == hk else { return false }
        hyperkeyDown = true
        hyperkeyUsed = false
        return true
    }

    func handleHyperkeyUp(_ keyCode: UInt16) -> Bool {
        guard let hk = hyperkeyCode, hk != 57, keyCode == hk else { return false }
        hyperkeyDown = false
        hyperkeyUsed = false
        return true
    }

    // Stamp hyper modifiers onto the event so other apps see Ctrl+Opt+Cmd+Shift
    func injectHyperModifiers(into event: CGEvent) {
        guard hyperkeyDown else { return }
        hyperkeyUsed = true
        event.flags = event.flags.union([.maskControl, .maskAlternate, .maskCommand, .maskShift])
    }

    /// Process a key event. Returns true if the event should be swallowed.
    func handleKey(_ keyCode: UInt16, flags: CGEventFlags) -> Bool {
        // Match against configured key bindings
        // Mask out device-dependent bits for reliable comparison
        let relevantMask: CGEventFlags = [.maskAlternate, .maskShift, .maskCommand, .maskControl]
        var pressedMods = flags.intersection(relevantMask)

        // Hyperkey held = all four modifiers
        if hyperkeyDown {
            hyperkeyUsed = true
            pressedMods = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        }

        // Device-dependent flag bits for distinguishing left vs right Alt/Option.
        // Right Alt (AltGr) is used for special characters on many keyboard layouts,
        // so we only respond to Left Alt for our bindings.
        let rightAltFlag: UInt64 = 0x40  // NX_DEVICERALTKEYMASK
        let rawFlags = flags.rawValue

        for binding in keyBindings {
            let bindMods = binding.modifiers.intersection(relevantMask)
            if keyCode == binding.keyCode && pressedMods == bindMods {
                // Only match left Alt (skip AltGr), but not when hyperkey is active
                if !hyperkeyDown && bindMods.contains(.maskAlternate) && (rawFlags & rightAltFlag) != 0 {
                    continue
                }
                dispatch(binding.action)
                return true
            }
        }

        return false
    }

    private func dispatch(_ action: WMAction) {
        DispatchQueue.main.async { [weak self] in
            self?.actionHandler?(action)
        }
    }

    // MARK: - Tap Health Check

    private func checkTapHealth() {
        guard let tap = eventTap else {
            // Tap was lost entirely, try to recreate
            panelessLog("Event tap lost, attempting to recreate")
            stop()
            start()
            return
        }

        if !CGEvent.tapIsEnabled(tap: tap) {
            panelessLog("Event tap was disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

// MARK: - C Callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        EventTap.shared?.reEnable()
        return Unmanaged.passUnretained(event)
    }

    guard let tap = EventTap.shared else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    switch type {
    case .flagsChanged:
        if tap.handleFlagsChanged(keyCode, flags: flags) {
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .keyDown:
        if tap.handleHyperkeyDown(keyCode) { return nil }
        if tap.handleKey(keyCode, flags: flags) { return nil }
        // No binding matched, but hyperkey held? Inject modifiers for other apps
        tap.injectHyperModifiers(into: event)
        return Unmanaged.passUnretained(event)

    case .keyUp:
        if tap.handleHyperkeyUp(keyCode) { return nil }
        tap.injectHyperModifiers(into: event)
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}
