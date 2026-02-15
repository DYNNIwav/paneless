import Cocoa

protocol WindowObserverDelegate: AnyObject {
    func windowCreated(windowID: CGWindowID, pid: pid_t, appName: String)
    func windowDestroyed(windowID: CGWindowID)
    func spaceChanged()
    func focusChanged()
    func focusChanged(windowID: CGWindowID)
    func applicationLaunched(pid: pid_t, name: String)
    func applicationTerminated(pid: pid_t, name: String)
    func applicationActivated(pid: pid_t, name: String)
}

class WindowObserver {
    weak var delegate: WindowObserverDelegate?

    private var knownWindows: Set<CGWindowID> = []
    private var pollingTimer: Timer?
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Burst-poll timer (50ms interval) for fast detection
    private var burstTimer: Timer?
    private var burstEndTime: Date?

    /// Pause/resume support to prevent race conditions during workspace switching
    private(set) var isPaused = false

    func pause() { isPaused = true }
    func resume() {
        isPaused = false
        pollWindows()
    }

    // Adaptive polling state
    private var lastChangeTime: Date = Date()
    private var currentPollInterval: TimeInterval = 0.5
    private let fastPollInterval: TimeInterval = 0.5
    private let slowPollInterval: TimeInterval = 3.0
    private let slowdownThreshold: TimeInterval = 5.0  // go slow after 5s of no changes

    // MARK: - Background Window Interceptor
    // Runs CGWindowList polling on a HIGH PRIORITY background thread during
    // app launches. Catches new windows at the WindowServer level and hides
    // them (alpha=0) before AX notifications even fire. This prevents the
    // flash of the window at its default position for slow apps.

    private let interceptorQueue = DispatchQueue(label: "com.paneless.interceptor", qos: .userInteractive)
    private var interceptorTimer: DispatchSourceTimer?
    /// Thread-safe snapshot of known window IDs for the interceptor
    private var interceptorKnown = Set<CGWindowID>()
    /// Windows already hidden by the interceptor (so we don't double-hide)
    private var interceptorHidden = Set<CGWindowID>()
    private let interceptorLock = NSLock()

    func start() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(spaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addAXObserver(for: app.processIdentifier)
        }

        // Start adaptive polling
        schedulePoll()

        pollWindows()
        panelessLog("Window observer started (adaptive polling)")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollingTimer?.invalidate()
        pollingTimer = nil
        burstTimer?.invalidate()
        burstTimer = nil
        stopInterceptor()

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

    /// Start the background window interceptor. Runs CGWindowList polling at
    /// ~8ms (display refresh rate) on a high-priority background thread.
    /// Any new window ID that appears is IMMEDIATELY hidden (alpha=0) before
    /// a single frame can render at the app's default position.
    func startInterceptor(duration: TimeInterval = 5.0) {
        // Sync current known windows to the interceptor
        interceptorLock.lock()
        interceptorKnown = knownWindows
        interceptorLock.unlock()

        // If already running, just extend the duration
        if interceptorTimer != nil { return }

        let conn = CGSMainConnectionID()
        let myPID = ProcessInfo.processInfo.processIdentifier
        let endTime = CACurrentMediaTime() + duration

        let timer = DispatchSource.makeTimerSource(queue: interceptorQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            if CACurrentMediaTime() > endTime {
                self.stopInterceptor()
                return
            }

            // Fast CGWindowList scan — same query as SpaceManager but inline
            // to avoid crossing to main thread
            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return }

            self.interceptorLock.lock()
            let known = self.interceptorKnown
            var hidden = self.interceptorHidden
            self.interceptorLock.unlock()

            for info in windowList {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                      let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let width = bounds["Width"], let height = bounds["Height"],
                      width > 50, height > 50
                else { continue }

                if ownerPID == myPID { continue }

                // New window we haven't seen — hide it immediately
                if !known.contains(windowID) && !hidden.contains(windowID) {
                    CGSSetWindowAlpha(conn, windowID, 0.0)
                    hidden.insert(windowID)
                }
            }

            self.interceptorLock.lock()
            self.interceptorHidden = hidden
            self.interceptorLock.unlock()
        }

        interceptorTimer = timer
        timer.resume()
    }

    private func stopInterceptor() {
        interceptorTimer?.cancel()
        interceptorTimer = nil
        interceptorLock.lock()
        interceptorHidden.removeAll()
        interceptorLock.unlock()
    }

    /// Notify the interceptor that a window is now known (so it stops hiding it)
    func interceptorAcknowledge(_ windowID: CGWindowID) {
        interceptorLock.lock()
        interceptorKnown.insert(windowID)
        interceptorHidden.remove(windowID)
        interceptorLock.unlock()
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

        // Start background interceptor — catches windows at WindowServer level
        // before AX notifications fire, hiding them instantly (alpha=0)
        startInterceptor(duration: 5.0)
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

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        delegate?.applicationActivated(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")
    }

    // MARK: - Polling

    private func pollWindows() {
        guard !isPaused else { return }
        let currentWindows = Set(SpaceManager.getWindowsOnCurrentSpace())

        let newWindows = currentWindows.subtracting(knownWindows)
        let conn = CGSMainConnectionID()
        for windowID in newWindows {
            // Pre-hide new windows before notifying delegate. The background
            // interceptor may have already hidden this window — that's fine,
            // CGSSetWindowAlpha is idempotent.
            CGSSetWindowAlpha(conn, windowID, 0.0)

            // Tell the interceptor we've claimed this window
            interceptorAcknowledge(windowID)

            if let info = SpaceManager.getWindowInfo(windowID) {
                delegate?.windowCreated(windowID: windowID, pid: info.pid, appName: info.appName)
                markActivity()
            } else {
                // Can't get info — restore alpha so window isn't stuck invisible
                CGSSetWindowAlpha(conn, windowID, 1.0)
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

    // Extract window ID from the notification element immediately (before async dispatch)
    // so we don't lose it to a race condition with NSWorkspace.frontmostApplication
    var notifWindowID: CGWindowID = 0
    if notifName == kAXFocusedWindowChangedNotification as String ||
       notifName == kAXWindowCreatedNotification as String {
        _ = _AXUIElementGetWindow(element, &notifWindowID)
    }

    // CRITICAL: Hide newly created windows IMMEDIATELY — before the main queue
    // dispatch. This prevents the window from ever being visible at the app's
    // default position. CGS calls are thread-safe for the main connection.
    // The Animator will fade the window in at the correct tiled position.
    if notifName == kAXWindowCreatedNotification as String && notifWindowID != 0 {
        let conn = CGSMainConnectionID()
        CGSSetWindowAlpha(conn, notifWindowID, 0.0)
    }

    DispatchQueue.main.async {
        // Skip all processing while paused (during workspace switching)
        guard !windowObserver.isPaused else { return }

        // Pass the window ID directly from the AX notification element.
        // This avoids a race where NSWorkspace.frontmostApplication hasn't
        // updated yet when the user clicks a window with the mouse.
        if notifName == kAXFocusedWindowChangedNotification as String {
            if notifWindowID != 0 {
                windowObserver.delegate?.focusChanged(windowID: notifWindowID)
            } else {
                windowObserver.delegate?.focusChanged()
            }
        }

        windowObserver.triggerPoll()
    }
}
