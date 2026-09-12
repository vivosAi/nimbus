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

    /// True once the tracking stack has been built, so a permission flap does
    /// not build it twice.
    private var isRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startNewSession()
        for (i, screen) in NSScreen.screens.enumerated() {
            Log.write("screen[\(i)] frame=\(screen.frame) scale=\(screen.backingScaleFactor)")
        }
        prefs.registerDefaults()

        statusItem = StatusItem(prefs: prefs)
        statusItem.onToggleEnabled = { [weak self] in self?.toggleEnabled() }
        statusItem.onGrantPermission = { [weak self] in self?.requestPermission() }
        statusItem.onQuit = { NSApp.terminate(nil) }

        permission.onChange = { [weak self] trusted in
            self?.permissionChanged(trusted)
        }
        permission.start()
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
            // Accessibility list, so the user has something to tick when the
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

        let tracker = FocusTracker()
        tracker.onChange = { [weak self] state in
            self?.focusChanged(state)
        }
        tracker.onMotionChanged = { [weak self] inMotion in
            self?.overlay?.setInMotion(inMotion)
        }
        tracker.start()
        self.tracker = tracker

        Log.write("tracking started")
    }

    private func stopTracking() {
        guard isRunning else { return }
        isRunning = false
        tracker?.stop()
        tracker = nil
        overlay?.hide()
        overlay = nil
        Log.write("tracking stopped")
    }

    /// Single funnel for focus changes. M3 will also drive the animator here.
    private func focusChanged(_ state: FocusState?) {
        overlay?.update(with: state)
    }

    private func toggleEnabled() {
        prefs.enabled.toggle()
        if prefs.enabled { startTracking() } else { stopTracking() }
    }
}
