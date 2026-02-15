import Cocoa

protocol WindowObserverDelegate: AnyObject {
    func windowCreated(windowID: CGWindowID, pid: pid_t, appName: String)
    func windowDestroyed(windowID: CGWindowID)
    func spaceChanged()
    func focusChanged()
    func applicationLaunched(pid: pid_t, name: String)
    func applicationTerminated(pid: pid_t, name: String)
}

class WindowObserver {
    weak var delegate: WindowObserverDelegate?

    private var knownWindows: Set<CGWindowID> = []
    private var pollingTimer: Timer?
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Burst-poll timer (50ms interval) for fast detection
    private var burstTimer: Timer?
    private var burstEndTime: Date?

    // Adaptive polling state
    private var lastChangeTime: Date = Date()
    private var currentPollInterval: TimeInterval = 0.5
    private let fastPollInterval: TimeInterval = 0.5
    private let slowPollInterval: TimeInterval = 3.0
    private let slowdownThreshold: TimeInterval = 5.0  // go slow after 5s of no changes

    func start() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(spaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addAXObserver(for: app.processIdentifier)
        }

        // Start adaptive polling
        schedulePoll()

        pollWindows()
        spaceyLog("Window observer started (adaptive polling)")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollingTimer?.invalidate()
        pollingTimer = nil
        burstTimer?.invalidate()
        burstTimer = nil

        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                 AXObserverGetRunLoopSource(observer),
                                 .defaultMode)
        }
        axObservers.removeAll()
    }

    var currentKnownWindows: Set<CGWindowID> { knownWindows }

    func syncKnownWindows(_ windows: Set<CGWindowID>) {
        knownWindows = windows
    }

    func triggerPoll() {
        pollWindows()
    }

    func startBurstPolling(duration: TimeInterval = 2.0) {
        burstEndTime = Date(timeIntervalSinceNow: duration)

        guard burstTimer == nil else { return }

        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            self.pollWindows()

            if let endTime = self.burstEndTime, Date() > endTime {
                timer.invalidate()
                self.burstTimer = nil
                self.burstEndTime = nil
            }
        }
    }

    // MARK: - Adaptive Polling

    private func schedulePoll() {
        pollingTimer?.invalidate()

        // Adaptive interval: fast when changes are happening, slow when idle
        let timeSinceLastChange = Date().timeIntervalSince(lastChangeTime)
        currentPollInterval = timeSinceLastChange > slowdownThreshold ? slowPollInterval : fastPollInterval

        pollingTimer = Timer.scheduledTimer(withTimeInterval: currentPollInterval, repeats: false) { [weak self] _ in
            self?.pollWindows()
            self?.schedulePoll()
        }
    }

    private func markActivity() {
        let wasIdle = Date().timeIntervalSince(lastChangeTime) > slowdownThreshold
        lastChangeTime = Date()

        // If we were in slow mode, immediately switch to fast polling
        if wasIdle {
            schedulePoll()
        }
    }

    // MARK: - Workspace Notifications

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        addAXObserver(for: app.processIdentifier)
        delegate?.applicationLaunched(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")

        markActivity()
        startBurstPolling(duration: 3.0)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        removeAXObserver(for: app.processIdentifier)
        delegate?.applicationTerminated(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")
        markActivity()
    }

    @objc private func spaceChanged(_ notification: Notification) {
        // With virtual workspaces, native space changes are informational only.
        delegate?.spaceChanged()
    }

    // MARK: - Polling

    private func pollWindows() {
        let currentWindows = Set(SpaceManager.getWindowsOnCurrentSpace())

        let newWindows = currentWindows.subtracting(knownWindows)
        for windowID in newWindows {
            if let info = SpaceManager.getWindowInfo(windowID) {
                delegate?.windowCreated(windowID: windowID, pid: info.pid, appName: info.appName)
                markActivity()
            }
        }

        let removedWindows = knownWindows.subtracting(currentWindows)
        for windowID in removedWindows {
            delegate?.windowDestroyed(windowID: windowID)
            markActivity()
        }

        knownWindows = currentWindows
    }

    // MARK: - AX Observers

    private func addAXObserver(for pid: pid_t) {
        guard axObservers[pid] == nil else { return }

        var observer: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &observer)
        guard err == .success, let observer = observer else { return }

        let appRef = AXUIElementCreateApplication(pid)

        let refPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, appRef,
                                  kAXWindowCreatedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXUIElementDestroyedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXFocusedWindowChangedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXWindowMiniaturizedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXWindowDeminiaturizedNotification as CFString, refPtr)

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
        axObservers[pid] = observer
    }

    private func removeAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }
}

// MARK: - AX Observer Callback

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let windowObserver = Unmanaged<WindowObserver>.fromOpaque(userData).takeUnretainedValue()
    let notifName = notification as String

    DispatchQueue.main.async {
        // Allow focus events through even during space transitions.
        // focusChanged() validates the window is tracked on the current space,
        // and doesn't call app.activate(), so it can't cause space-switching loops.
        // Suppressing focus events for 1 second made clicking/keybinds unresponsive
        // after space changes.
        if notifName == kAXFocusedWindowChangedNotification as String {
            windowObserver.delegate?.focusChanged()
        }

        windowObserver.triggerPoll()
        windowObserver.startBurstPolling(duration: 0.5)
    }
}
