import AppKit
import FocusRingKit

/// Wires the pieces together and owns their lifetimes. Everything downstream of
/// focus tracking is driven from here; nothing here knows how a ring is drawn.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let prefs = Preferences.shared
    private let permission = AXPermission()

    private var statusItem: StatusItem!
    private var permissionWindow: PermissionWindow?
    private var tracker: FocusTracker?
    private var overlay: OverlayController?

    /// Checks whether a palette rotation is due. Deliberately coarse — the
    /// interval is measured in tens of minutes, so a half-minute of slop is
    /// invisible and this costs nothing.
    private var rotationTimer: Timer?
    private let idleMonitor = IdleMonitor()
    private let rotationCheckInterval: TimeInterval = 30

    private var isRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startNewSession()
        for (i, screen) in NSScreen.screens.enumerated() {
            Log.write("screen[\(i)] frame=\(screen.frame) scale=\(screen.backingScaleFactor)")
        }
        prefs.registerDefaults()

        statusItem = StatusItem(prefs: prefs)
        statusItem.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        statusItem.onGrantPermission = { [weak self] in self?.requestPermission() }
        statusItem.onNextColor = { [weak self] in self?.rotatePalette(reason: "user") }
        statusItem.onChooseColor = { [weak self] palette in self?.choosePalette(palette) }
        statusItem.onQuit = { NSApp.terminate(nil) }

        permission.onChange = { [weak self] trusted in
            self?.permissionChanged(trusted)
        }
        permission.start()

        observeSystemEvents()

        idleMonitor.threshold = prefs.idleThreshold
        idleMonitor.onIdleChanged = { [weak self] idle in self?.idleChanged(idle) }
        idleMonitor.onDisplaySleepChanged = { [weak self] asleep in
            self?.overlay?.setDisplaysAsleep(asleep)
            if !asleep { self?.userReturned() }
        }
        idleMonitor.start()
    }

    /// Going idle stops the animation. Coming back gets a full flare: after time
    /// away you are at your most likely to type into whichever window happens to
    /// hold focus, which is the failure this app exists to prevent.
    private func idleChanged(_ idle: Bool) {
        overlay?.setIdle(idle)
        if !idle, prefs.flareOnReturn { overlay?.flareNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistPaletteState()
    }

    // MARK: - Permission

    private func permissionChanged(_ trusted: Bool) {
        statusItem.isTrusted = trusted
        Log.write("Accessibility trusted: \(trusted)")

        if trusted {
            permissionWindow?.close()
            permissionWindow = nil
            startTracking()
        } else {
            stopTracking()
            showPermissionWindow()
        }
    }

    private func showPermissionWindow() {
        guard permissionWindow == nil else { return }
        let window = PermissionWindow()
        window.onOpenSettings = {
            // Prompt first: on a fresh install this adds FocusRing to the
            // Accessibility list, so there is something to tick when the
            // settings pane opens.
            AXPermission.promptForTrust()
            AXPermission.openSystemSettings()
        }
        window.show()
        permissionWindow = window
    }

    private func requestPermission() {
        AXPermission.promptForTrust()
        AXPermission.openSystemSettings()
    }

    // MARK: - Lifecycle of the tracking stack

    private func startTracking() {
        guard !isRunning, prefs.enabled else { return }
        isRunning = true

        let overlay = OverlayController(prefs: prefs)
        self.overlay = overlay
        restorePaletteState()

        let tracker = FocusTracker()
        tracker.onChange = { [weak self] state in self?.focusChanged(state) }
        tracker.onMotionChanged = { [weak self] inMotion in
            self?.overlay?.setInMotion(inMotion)
        }
        tracker.start()
        self.tracker = tracker

        startRotationTimer()
        Log.write("tracking started")
    }

    private func stopTracking() {
        guard isRunning else { return }
        isRunning = false
        persistPaletteState()
        rotationTimer?.invalidate()
        rotationTimer = nil
        tracker?.stop()
        tracker = nil
        overlay?.hide()
        overlay = nil
        Log.write("tracking stopped")
    }

    /// Single funnel for focus changes.
    private func focusChanged(_ state: FocusState?) {
        overlay?.update(with: state)
        statusItem.frontmostBundleID = state?.bundleID
    }

    private func settingsChanged() {
        idleMonitor.threshold = prefs.idleThreshold
        if prefs.enabled {
            startTracking()
            overlay?.applySettings()
            // Re-place immediately so a width or brightness change is visible
            // without waiting for the next window switch.
            overlay?.refresh()
        } else {
            stopTracking()
        }
        statusItem.currentPaletteName = overlay?.currentPalette.name ?? ""
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        // Waking and unlocking are both "the user has just come back", which is
        // exactly when the ring is most worth noticing — and the best moment for
        // a new colour, since novelty is most useful on return (§8.5).
        center.addObserver(self, selector: #selector(userReturned),
                           name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(userReturned),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(userReturned),
                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func userReturned() {
        Log.write("user returned — flaring and rotating")
        rotatePalette(reason: "return")
        if prefs.flareOnReturn { overlay?.flareNow() }
    }

    // MARK: - Palette rotation

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        let timer = Timer(timeInterval: rotationCheckInterval, repeats: true) { [weak self] _ in
            self?.rotateIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func rotateIfDue() {
        let interval = prefs.paletteInterval
        guard interval > 0 else { return }
        let last = prefs.paletteChangedAt ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        rotatePalette(reason: "timer")
    }

    private func rotatePalette(reason: String) {
        guard let overlay else { return }
        var generator = SystemRandomNumberGenerator()
        let next = overlay.pickNextPalette(excluding: prefs.disabledPalettes,
                                           using: &generator)
        overlay.transitionPalette(to: next)
        persistPaletteState()
        statusItem.currentPaletteName = next.name
        Log.write("palette -> \(next.name) (\(reason))")
    }

    private func choosePalette(_ palette: Palette) {
        guard let overlay else { return }
        overlay.transitionPalette(to: palette)
        persistPaletteState()
        statusItem.currentPaletteName = palette.name
        // A manual pick restarts the rotation clock, so the timer does not
        // change it out from under the user moments after they chose it.
        Log.write("palette -> \(palette.name) (chosen)")
    }

    /// Persisted so a restart resumes the cycle rather than resetting it (§8.5).
    private func persistPaletteState() {
        guard let overlay else { return }
        prefs.paletteIndex = overlay.paletteIndex
        prefs.paletteRecent = overlay.paletteRecent
        prefs.paletteChangedAt = Date()
    }

    private func restorePaletteState() {
        overlay?.restorePalette(index: prefs.paletteIndex, recent: prefs.paletteRecent)
        statusItem.currentPaletteName = overlay?.currentPalette.name ?? ""
        // If the machine was off for longer than the interval, the next rotation
        // is already overdue; let the timer catch it on its first tick.
    }
}
