import AppKit
import ApplicationServices

/// The app does nothing without Accessibility permission, so this watches the
/// grant rather than checking once at launch: tick the checkbox in System
/// Settings and Nimbus starts working within a second, no restart (§6.1).
final class AXPermission {

    /// Fires on the main queue whenever the trust state changes, including the
    /// initial value.
    var onChange: ((Bool) -> Void)?

    private(set) var isTrusted: Bool = false
    private var timer: Timer?

    /// Poll interval. §6.1 requires the grant to be noticed within 1s.
    private let pollInterval: TimeInterval = 1.0

    static var currentlyTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask the system to show its "Nimbus would like to control this computer"
    /// alert. Only call this from an explicit user action — calling it on every
    /// launch trains people to dismiss it.
    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func start() {
        isTrusted = AXPermission.currentlyTrusted
        onChange?(isTrusted)

        // A repeating timer rather than an observer: TCC broadcasts no
        // notification for a grant, so polling is the only option. One wake per
        // second at this cost is immaterial, and it stops once trust is granted.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common so the poll keeps running while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let now = AXPermission.currentlyTrusted
        guard now != isTrusted else { return }
        isTrusted = now
        onChange?(now)
        // Revocation is possible too (tccutil reset, or the user unticking), so
        // keep polling rather than stopping on the first grant.
    }
}
