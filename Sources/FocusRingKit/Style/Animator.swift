import Foundation

/// The flare-and-settle curve (§8.4).
///
/// The eye detects change far better than steady state, so a focus change gets
/// a bright pulse that relaxes into a calm baseline. Kept pure — time is passed
/// in rather than read — so the curve can be tested without waiting for it.
public final class Animator {

    /// Baseline once the flare has settled.
    public var idleIntensity: Float
    /// Seconds for the pulse to relax to the baseline.
    public var flareDuration: Float

    private var flareStartedAt: TimeInterval?

    public init(idleIntensity: Float = 0.30, flareDuration: Float = 2.5) {
        self.idleIntensity = idleIntensity
        self.flareDuration = flareDuration
    }

    /// Start a pulse. Called on a change to a *different* window, and on return
    /// from idle — not on every geometry update, or the ring would never settle.
    public func flare(at now: TimeInterval) {
        flareStartedAt = now
    }

    /// 1 at the instant of a flare, decaying to 0. Everything else is derived
    /// from this so the brightness, the width and the speed all relax together.
    public func flareProgress(at now: TimeInterval) -> Float {
        guard let start = flareStartedAt, flareDuration > 0 else { return 0 }
        let elapsed = Float(now - start)
        if elapsed < 0 { return 1 }
        if elapsed >= flareDuration { return 0 }
        // Ease-out: fast at first, long tail. exp(-3) ≈ 0.05, so the pulse is
        // 95% spent by the end of flareDuration.
        return exp(-3.0 * elapsed / flareDuration)
    }

    public func intensity(at now: TimeInterval) -> Float {
        idleIntensity + (1.0 - idleIntensity) * flareProgress(at: now)
    }

    /// The band visibly swells on a flare and relaxes back (§8.4).
    public func bandScale(at now: TimeInterval) -> Float {
        1.0 + 0.6 * flareProgress(at: now)
    }

    /// ...and the motion speeds up with it.
    public func speedScale(at now: TimeInterval) -> Float {
        1.0 + 0.8 * flareProgress(at: now)
    }

    /// True while a pulse is still visibly running; lets the renderer drop back
    /// to the idle frame rate once it is over.
    public func isFlaring(at now: TimeInterval) -> Bool {
        flareProgress(at: now) > 0.02
    }
}
