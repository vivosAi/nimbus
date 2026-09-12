import AppKit
import ApplicationServices
import FocusRingKit

/// Watches which window has keyboard focus and where it is.
///
/// Threading, which is the whole difficulty here:
/// - `AXObserver` run loop sources are installed on the **main** run loop.
///   Installing them on a thread without a running run loop is the classic
///   silent failure: the observer is created successfully and never fires.
/// - Every AX *read* happens on `readQueue`, never on main, because a single
///   read into a hung app can block for as long as the messaging timeout.
/// - Results are converted to AppKit coordinates and published back on main.
final class FocusTracker {

    /// Called on the main queue. `nil` means "nothing should be ringed".
    var onChange: ((FocusState?) -> Void)?

    /// True while the focused window is being dragged or resized.
    var onMotionChanged: ((Bool) -> Void)?

    private let readQueue = DispatchQueue(label: "com.vivasonico.focusring.ax",
                                          qos: .userInitiated)

    // Observed application
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var axApp: AXUIElement?

    // Observed window within that application
    private var axWindow: AXUIElement?

    /// Periodic re-sync. Everything else here is notification-driven, and a
    /// dropped notification leaves the ring sitting on a window that no longer
    /// has focus with nothing to correct it. Some apps never emit
    /// focusedWindowChanged at all, and notifications can be missed across a
    /// Space switch. One cheap AX read every couple of seconds heals all of it.
    private var resyncTimer: Timer?
    private let resyncInterval: TimeInterval = 2.0

    // Motion mode (§6.5)
    private var motionTimer: Timer?
    private var lastMotionAt: Date?
    private var consecutiveReadFailures = 0

    private var lastPublished: FocusState?
    private var isRunning = false

    /// How often to check whether a drag has finished. This timer does no AX
    /// work at all — it only compares timestamps — so it can be slow and cheap.
    private let motionCheckInterval: TimeInterval = 1.0 / 20.0
    private let motionExitDelay: TimeInterval = 0.25
    private var isInMotion = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(recompute),
                           name: NSWorkspace.didWakeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(recompute),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Don't wait for the first app switch to show something.
        attachToFrontmostApplication()
        startResyncTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        resyncTimer?.invalidate()
        resyncTimer = nil
        exitMotionMode()
        detachObserver()
        publish(nil)
    }

    deinit { stop() }

    private func startResyncTimer() {
        resyncTimer?.invalidate()
        let timer = Timer(timeInterval: resyncInterval, repeats: true) { [weak self] _ in
            self?.resync()
        }
        RunLoop.main.add(timer, forMode: .common)
        resyncTimer = timer
    }

    /// Reconcile against reality. `publish` de-duplicates, so when nothing has
    /// drifted this costs one AX read and changes nothing.
    private func resync() {
        guard isRunning, !isInMotion else { return }

        // If the frontmost app is not the one we are observing, a workspace
        // notification was missed; rebuild the observer rather than re-reading
        // a stale application element.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != observedPID {
            Log.write("resync: frontmost is \(front.bundleIdentifier ?? "pid \(front.processIdentifier)"), "
                      + "observing \(observedPID.map(String.init) ?? "nothing") — reattaching")
            attach(to: front)
            return
        }
        refreshGeometry(reason: nil)
    }

    // MARK: - Workspace events

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        attach(to: app)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        // Only tear down if the app that died is the one we were watching;
        // otherwise a background app quitting would blank the ring.
        if app.processIdentifier == observedPID {
            detachObserver()
            publish(nil)
        }
    }

    /// Screen layout changed, or the machine woke. Both invalidate the cached
    /// primary-display height that every coordinate conversion depends on, so
    /// re-read geometry from scratch rather than reusing the last frame.
    @objc private func recompute() {
        refreshGeometry(reason: "recompute")
    }

    private func attachToFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            publish(nil)
            return
        }
        attach(to: app)
    }

    // MARK: - Per-application observer

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != observedPID else {
            refreshGeometry(reason: "reactivated")
            return
        }

        detachObserver()

        // Never ring ourselves (§10).
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            publish(nil)
            return
        }

        let axApp = AX.makeApplication(pid)
        self.observedPID = pid
        self.axApp = axApp

        // Read and publish geometry *before* building the observer. Creating an
        // AXObserver and registering six notifications is the slow part of an
        // app switch, and doing it first delays the ring visibly.
        refreshGeometry(reason: "attached to \(app.bundleIdentifier ?? "pid \(pid)")")

        var observer: AXObserver?
        let result = AXObserverCreate(pid, focusTrackerObserverCallback, &observer)
        guard result == .success, let observer else {
            Log.write("AXObserverCreate failed for pid \(pid): \(result.rawValue)")
            return
        }
        self.observer = observer

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in FocusTracker.applicationNotifications {
            AXObserverAddNotification(observer, axApp, name as CFString, refcon)
        }

        // Main run loop, in .common mode so notifications keep arriving while a
        // menu is tracking or a window is being resized.
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .commonModes)
    }

    private func detachObserver() {
        exitMotionMode()

        if let observer {
            if let axApp {
                for name in FocusTracker.applicationNotifications {
                    AXObserverRemoveNotification(observer, axApp, name as CFString)
                }
            }
            unobserveWindow()
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .commonModes)
        }

        observer = nil
        observedPID = nil
        axApp = nil
        axWindow = nil
    }

    // Bridged once, as stored constants: these are CFString globals, and using
    // `x as String` directly inside a switch pattern compiles to an always-true
    // cast rather than a comparison.
    private enum Note {
        static let focusedWindowChanged = kAXFocusedWindowChangedNotification as String
        static let applicationActivated = kAXApplicationActivatedNotification as String
        static let applicationHidden    = kAXApplicationHiddenNotification as String
        static let applicationShown     = kAXApplicationShownNotification as String
        static let windowMiniaturized   = kAXWindowMiniaturizedNotification as String
        static let windowDeminiaturized = kAXWindowDeminiaturizedNotification as String
        static let windowMoved          = kAXWindowMovedNotification as String
        static let windowResized        = kAXWindowResizedNotification as String
        static let elementDestroyed     = kAXUIElementDestroyedNotification as String
    }

    private static let applicationNotifications: [String] = [
        Note.focusedWindowChanged,
        Note.applicationActivated,
        Note.applicationHidden,
        Note.applicationShown,
        Note.windowMiniaturized,
        Note.windowDeminiaturized,
    ]

    private static let windowNotifications: [String] = [
        Note.windowMoved,
        Note.windowResized,
        Note.elementDestroyed,
    ]

    /// Window-level notifications must be re-registered on every focus change,
    /// and the previous registration removed, or observers leak one per window
    /// the user ever touches.
    private func observeWindow(_ window: AXUIElement) {
        guard let observer else { return }
        unobserveWindow()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in FocusTracker.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
        axWindow = window
    }

    private func unobserveWindow() {
        guard let observer, let axWindow else { return }
        for name in FocusTracker.windowNotifications {
            AXObserverRemoveNotification(observer, axWindow, name as CFString)
        }
        self.axWindow = nil
    }

    // MARK: - Notification dispatch

    fileprivate func handle(notification: String, element: AXUIElement) {
        switch notification {
        case Note.windowMoved, Note.windowResized:
            enterMotionMode()

        case Note.elementDestroyed, Note.applicationHidden, Note.windowMiniaturized:
            exitMotionMode()
            publish(nil)

        default:
            refreshGeometry(reason: notification)
        }
    }

    // MARK: - Motion mode (§6.5)

    /// A drag or resize started. Rather than chasing the window with 60 Hz AX
    /// reads — which lag anyway, because the notifications are coalesced — the
    /// ring stands down until the window comes to rest.
    private func enterMotionMode() {
        lastMotionAt = Date()

        if !isInMotion {
            isInMotion = true
            onMotionChanged?(true)
        }

        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: motionCheckInterval, repeats: true) { [weak self] _ in
            guard let self, let last = self.lastMotionAt else { return }
            if Date().timeIntervalSince(last) > self.motionExitDelay {
                self.exitMotionMode()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    /// The window has come to rest: re-read its geometry once, then bring the
    /// ring back at the correct place rather than at the stale pre-drag frame.
    private func exitMotionMode() {
        motionTimer?.invalidate()
        motionTimer = nil
        lastMotionAt = nil

        guard isInMotion else { return }
        isInMotion = false
        refreshGeometry(reason: nil)
        onMotionChanged?(false)
    }

    // MARK: - Reading geometry

    /// Reads the focused window off the main thread and publishes the result.
    /// `reason` is logged; pass nil for the high-frequency motion polls so the
    /// log is not flooded.
    private func refreshGeometry(reason: String?) {
        guard isRunning, let axApp, let pid = observedPID else { return }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        readQueue.async { [weak self] in
            guard let self else { return }

            guard let focused = AX.element(axApp, kAXFocusedWindowAttribute as String),
                  let window = AX.resolveToWindow(focused) ?? Optional(focused),
                  let axFrame = AX.frame(window) else {
                self.readFailed(reason: reason)
                return
            }

            // §6.2: ignore non-standard windows unless they have a sane size —
            // panels and pickers otherwise pull the ring off the real window.
            let subrole = AX.string(window, kAXSubroleAttribute as String)
            let isStandard = subrole == (kAXStandardWindowSubrole as String)
            guard isStandard || Geometry.isSensible(axFrame) else {
                self.readFailed(reason: reason)
                return
            }

            let isFullScreen = AX.bool(window, "AXFullScreen") ?? false

            DispatchQueue.main.async {
                self.consecutiveReadFailures = 0
                self.observeWindow(window)

                guard Geometry.isSensible(axFrame) else {
                    self.publish(nil)
                    return
                }
                // Converted on main so `primaryHeight` is read fresh from
                // NSScreen rather than cached across a display change.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let frame = Geometry.axToScreen(axFrame, primaryHeight: primaryHeight)

                let state = FocusState(pid: pid,
                                       bundleID: bundleID,
                                       windowID: nil,
                                       frame: frame,
                                       isFullScreen: isFullScreen)
                if let reason {
                    Log.write("\(reason): \(bundleID ?? "pid \(pid)") "
                          + "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) "
                          + "\(Int(frame.width))x\(Int(frame.height)) "
                          + "fullScreen=\(isFullScreen)")
                }
                self.publish(state)
            }
        }
    }

    private func readFailed(reason: String?) {
        DispatchQueue.main.async {
            self.consecutiveReadFailures += 1
            // §6.5: two failures in a row means hide, rather than leaving the
            // ring stranded around where the window used to be.
            if self.consecutiveReadFailures >= 2 {
                self.exitMotionMode()
                self.publish(nil)
            }
            if let reason {
                Log.write("\(reason): no usable focused window")
            }
        }
    }

    private func publish(_ state: FocusState?) {
        guard state != lastPublished else { return }
        lastPublished = state
        onChange?(state)
    }
}

/// C callback trampoline. `refcon` carries the tracker unretained — the tracker
/// removes every notification before it deallocates, so it always outlives this.
private func focusTrackerObserverCallback(_ observer: AXObserver,
                                          _ element: AXUIElement,
                                          _ notification: CFString,
                                          _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification: notification as String, element: element)
}
