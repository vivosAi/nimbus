import AppKit
import CoreGraphics

/// Watches for the user going away from and returning to the machine.
///
/// Two distinct events, with opposite requirements:
///
/// - **Display sleep.** Nobody can see the screen, so rendering is pure waste.
///   Stop completely.
/// - **Input idle.** The user may well be sitting there reading. The animation
///   can stop to save power, but the ring itself must stay on screen: walking
///   back to the machine and looking at which window has keyboard focus —
///   before touching anything — is the case this app exists for. A ring that
///   removed itself while idle would be absent at exactly that moment.
final class IdleMonitor {

    /// True when the user has been away longer than `threshold`.
    var onIdleChanged: ((Bool) -> Void)?
    /// True while the displays are asleep.
    var onDisplaySleepChanged: ((Bool) -> Void)?

    var threshold: TimeInterval = 600

    private(set) var isIdle = false
    private(set) var displaysAreAsleep = false

    private var timer: Timer?

    /// One second. The check is a handful of cheap event-source queries with no
    /// AX or GPU work, and a slower poll would delay the flare that greets the
    /// user on their return.
    private let pollInterval: TimeInterval = 1.0

    /// Seconds since the last input of any kind.
    ///
    /// `kCGAnyInputEventType` cannot be expressed as a `CGEventType` in Swift —
    /// its raw value is not a declared case — so the minimum across the event
    /// types that actually indicate presence is used instead.
    static var secondsSinceLastInput: TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensSlept),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensWoke),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }

    private func poll() {
        guard threshold > 0 else {
            setIdle(false)
            return
        }
        setIdle(IdleMonitor.secondsSinceLastInput >= threshold)
    }

    private func setIdle(_ idle: Bool) {
        guard idle != isIdle else { return }
        isIdle = idle
        Log.write("idle -> \(idle)")
        onIdleChanged?(idle)
    }

    @objc private func screensSlept() {
        guard !displaysAreAsleep else { return }
        displaysAreAsleep = true
        Log.write("displays asleep")
        onDisplaySleepChanged?(true)
    }

    @objc private func screensWoke() {
        guard displaysAreAsleep else { return }
        displaysAreAsleep = false
        Log.write("displays awake")
        onDisplaySleepChanged?(false)
    }
}
