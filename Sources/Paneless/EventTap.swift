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

    func start() {
        EventTap.shared = self

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            panelessLog("Event tap re-enabled")
        }
    }

    /// Process a key event. Returns true if the event should be swallowed.
    func handleKey(_ keyCode: UInt16, flags: CGEventFlags) -> Bool {
        // Match against configured key bindings
        // Mask out device-dependent bits for reliable comparison
        let relevantMask: CGEventFlags = [.maskAlternate, .maskShift, .maskCommand, .maskControl]
        let pressedMods = flags.intersection(relevantMask)

        for binding in keyBindings {
            let bindMods = binding.modifiers.intersection(relevantMask)
            if keyCode == binding.keyCode && pressedMods == bindMods {
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

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    if let tap = EventTap.shared, tap.handleKey(keyCode, flags: flags) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
