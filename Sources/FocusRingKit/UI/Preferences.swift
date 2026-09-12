import Foundation
import CoreGraphics

/// Typed accessors over `UserDefaults`, suite `com.vivasonico.focusring`.
/// Every setting the menu (§9) exposes lives here with its default.
public final class Preferences {

    public static let suiteName = "com.vivasonico.focusring"
    public static let shared = Preferences()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Preferences.suiteName) ?? .standard
    }

    // MARK: - Keys

    private enum Key {
        static let enabled          = "enabled"
        static let idleIntensity    = "idleIntensity"
        static let flareDuration    = "flareDuration"
        static let bandWidth        = "bandWidth"
        static let frameRate        = "frameRate"
        static let paletteInterval  = "paletteInterval"
        static let paletteIndex     = "paletteIndex"
        static let paletteChangedAt = "paletteChangedAt"
        static let paletteRecent    = "paletteRecent"
        static let disabledPalettes = "disabledPalettes"
        static let exclusions       = "exclusions"
        static let hideInFullScreen = "hideInFullScreen"
        static let idleBehavior     = "idleBehavior"
        static let idleThreshold    = "idleThreshold"
        static let flareOnReturn    = "flareOnReturn"
        static let margin           = "margin"
        static let hideWhileDragging = "hideWhileDragging"
        static let debugMode        = "debugMode"
        static let motionSpeed      = "motionSpeed"
        static let turbulence       = "turbulence"
        static let openAtLogin      = "openAtLogin"
    }

    /// Registered rather than scattered through the accessors, so the whole
    /// default configuration is readable in one place.
    public func registerDefaults() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.idleIntensity: 0.30,
            Key.flareDuration: 2.5,
            Key.bandWidth: BandWidth.normal.rawValue,
            Key.frameRate: 30,
            Key.paletteInterval: 1800.0,          // 30 minutes
            Key.paletteIndex: 0,
            Key.paletteRecent: [Int](),
            Key.disabledPalettes: [String](),
            Key.exclusions: [String](),
            Key.hideInFullScreen: true,
            Key.idleBehavior: IdleBehavior.freeze.rawValue,
            Key.idleThreshold: 600.0,             // 10 minutes
            Key.flareOnReturn: true,
            // Wide enough that the bloom fades out before the overlay's edge
            // rather than being clipped into a visible rectangle, with room for
            // the band swelling 1.6x at the peak of a flare.
            Key.margin: 48.0,
            Key.hideWhileDragging: true,
            Key.motionSpeed: MotionSpeed.normal.rawValue,
            Key.turbulence: Turbulence.normal.rawValue,
        ])
    }

    // MARK: - Enumerated settings

    public enum BandWidth: String, CaseIterable {
        case thin, normal, thick

        /// (inside the window edge, outside it), in points. §7.
        public var points: (inner: CGFloat, outer: CGFloat) {
            switch self {
            case .thin:   return (4, 12)
            case .normal: return (6, 18)
            case .thick:  return (9, 28)
            }
        }
    }

    /// How fast the light travels around the ring. Kept well under any rate
    /// that could read as flicker — §8.3's photosensitivity constraint is a
    /// hard floor, not a preference.
    public enum MotionSpeed: String, CaseIterable {
        case calm, normal, lively

        public var flowSpeed: Float {
            switch self {
            case .calm:   return 0.22
            case .normal: return 0.45
            case .lively: return 0.85
            }
        }

        public var title: String {
            switch self {
            case .calm:   return "Calm"
            case .normal: return "Normal"
            case .lively: return "Lively"
            }
        }
    }

    /// How many distinct features there are around the ring. Low values give
    /// broad slow swells; high values give fine churn.
    public enum Turbulence: String, CaseIterable {
        case smooth, normal, churny

        public var noiseScale: Float {
            switch self {
            case .smooth: return 2.5
            case .normal: return 4.0
            case .churny: return 6.5
            }
        }

        public var title: String {
            switch self {
            case .smooth: return "Smooth"
            case .normal: return "Normal"
            case .churny: return "Churny"
            }
        }
    }

    /// What happens after `idleThreshold` seconds with no keyboard or mouse input.
    ///
    /// The default is `.freeze`, not `.fadeOut`: pausing an `MTKView` stops
    /// redrawing but leaves the last frame on screen, so the ring still marks the
    /// focused window when you walk back to the machine and look at it before
    /// touching anything — which is the case this app exists for. The GPU is idle
    /// either way.
    public enum IdleBehavior: String, CaseIterable {
        case alwaysAnimate      // never stop; costs the most power
        case freeze             // stop animating, keep the ring visible (default)
        case fadeOut            // stop animating and hide the ring entirely
    }

    // MARK: - Accessors

    public var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Baseline brightness once the flare has settled. Subtle/Normal/Loud in §9
    /// map to 0.18 / 0.30 / 0.50.
    public var idleIntensity: Double {
        get { defaults.double(forKey: Key.idleIntensity) }
        set { defaults.set(newValue, forKey: Key.idleIntensity) }
    }

    /// Seconds for the focus-change flare to relax to `idleIntensity`.
    public var flareDuration: Double {
        get { defaults.double(forKey: Key.flareDuration) }
        set { defaults.set(newValue, forKey: Key.flareDuration) }
    }

    public var motionSpeed: MotionSpeed {
        get { MotionSpeed(rawValue: defaults.string(forKey: Key.motionSpeed) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.motionSpeed) }
    }

    public var turbulence: Turbulence {
        get { Turbulence(rawValue: defaults.string(forKey: Key.turbulence) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.turbulence) }
    }

    /// Mirrors `SMAppService` registration so the menu can show a checkmark
    /// without querying the service on every menu open.
    public var openAtLogin: Bool {
        get { defaults.bool(forKey: Key.openAtLogin) }
        set { defaults.set(newValue, forKey: Key.openAtLogin) }
    }

    public var bandWidth: BandWidth {
        get { BandWidth(rawValue: defaults.string(forKey: Key.bandWidth) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.bandWidth) }
    }

    public var frameRate: Int {
        get { defaults.integer(forKey: Key.frameRate) }
        set { defaults.set(newValue, forKey: Key.frameRate) }
    }

    /// Seconds between palette changes; 0 means never.
    public var paletteInterval: TimeInterval {
        get { defaults.double(forKey: Key.paletteInterval) }
        set { defaults.set(newValue, forKey: Key.paletteInterval) }
    }

    /// Persisted so a restart resumes the rotation rather than resetting it (§8.5).
    public var paletteIndex: Int {
        get { defaults.integer(forKey: Key.paletteIndex) }
        set { defaults.set(newValue, forKey: Key.paletteIndex) }
    }

    public var paletteChangedAt: Date? {
        get { defaults.object(forKey: Key.paletteChangedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.paletteChangedAt) }
    }

    /// The last few palette indices, so a rotation never repeats too soon.
    public var paletteRecent: [Int] {
        get { defaults.array(forKey: Key.paletteRecent) as? [Int] ?? [] }
        set { defaults.set(newValue, forKey: Key.paletteRecent) }
    }

    public var disabledPalettes: Set<String> {
        get { Set(defaults.array(forKey: Key.disabledPalettes) as? [String] ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.disabledPalettes) }
    }

    /// Bundle IDs that never get a ring. The escape hatch for apps that
    /// misreport their geometry (§10) — we do not special-case them in code.
    public var exclusions: Set<String> {
        get { Set(defaults.array(forKey: Key.exclusions) as? [String] ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.exclusions) }
    }

    public var hideInFullScreen: Bool {
        get { defaults.bool(forKey: Key.hideInFullScreen) }
        set { defaults.set(newValue, forKey: Key.hideInFullScreen) }
    }

    public var idleBehavior: IdleBehavior {
        get { IdleBehavior(rawValue: defaults.string(forKey: Key.idleBehavior) ?? "") ?? .freeze }
        set { defaults.set(newValue.rawValue, forKey: Key.idleBehavior) }
    }

    public var idleThreshold: TimeInterval {
        get { defaults.double(forKey: Key.idleThreshold) }
        set { defaults.set(newValue, forKey: Key.idleThreshold) }
    }

    /// Fire a full flare on the first input after an idle stretch, and on wake
    /// and unlock. Returning to the machine is exactly when you are most likely
    /// to type into the wrong window.
    public var flareOnReturn: Bool {
        get { defaults.bool(forKey: Key.flareOnReturn) }
        set { defaults.set(newValue, forKey: Key.flareOnReturn) }
    }

    /// Renderer diagnostic; see `Uniforms.debugMode`. Set with
    /// `defaults write com.vivasonico.focusring debugMode -int 2`.
    public var debugMode: Int {
        get { defaults.integer(forKey: Key.debugMode) }
        set { defaults.set(newValue, forKey: Key.debugMode) }
    }

    /// Hide the ring while a window is being dragged or resized.
    ///
    /// The spec (§6.5) instead polls AX at 60 Hz during a drag to stop the ring
    /// trailing the window. Hiding is both cheaper and more useful: while you
    /// are dragging a window you already know which one is active, so the ring
    /// has nothing to tell you, and the whole class of lag disappears with it.
    public var hideWhileDragging: Bool {
        get { defaults.bool(forKey: Key.hideWhileDragging) }
        set { defaults.set(newValue, forKey: Key.hideWhileDragging) }
    }

    /// How far the overlay window is outset beyond the tracked window (§7).
    public var margin: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.margin)) }
        set { defaults.set(Double(newValue), forKey: Key.margin) }
    }
}
