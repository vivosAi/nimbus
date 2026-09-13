import Foundation
import simd

/// Rotates the color scheme over time and cross-fades between schemes (§8.5).
///
/// Rotation exists to stop the ring becoming invisible through familiarity, so
/// the selection deliberately avoids repeating recent palettes, and transitions
/// are always faded — a hard cut reads as a glitch rather than as a change.
public final class PaletteController {

    public private(set) var current: Palette
    public private(set) var recent: [Int]

    private var previous: Palette?
    private var transitionStartedAt: TimeInterval?

    /// Cross-fade length. Long enough to read as a change, short enough not to
    /// spend most of its life in a muddy intermediate mix.
    public let transitionDuration: TimeInterval = 3.0

    /// How many recent palettes may not be reused. With ten palettes, avoiding
    /// the last three keeps the sequence from feeling like it has favourites.
    public static let recentMemory = 3

    private let available: [Palette]

    public init(palettes: [Palette] = Palette.all,
                startIndex: Int = 0,
                recent: [Int] = []) {
        let list = palettes.isEmpty ? Palette.all : palettes
        self.available = list
        self.current = list[min(max(startIndex, 0), list.count - 1)]
        self.recent = recent
    }

    public var currentIndex: Int {
        available.firstIndex(of: current) ?? 0
    }

    /// Pick the next palette: never the current one, and never one of the last
    /// few. Falls back gracefully when the user has disabled most of the list.
    public func pickNext<G: RandomNumberGenerator>(excluding disabled: Set<String> = [],
                                                  using generator: inout G) -> Palette {
        let enabled = available.filter { !disabled.contains($0.name) }
        guard enabled.count > 1 else { return enabled.first ?? current }

        let recentNames = Set(recent.compactMap { index -> String? in
            guard available.indices.contains(index) else { return nil }
            return available[index].name
        })

        var candidates = enabled.filter { $0 != current && !recentNames.contains($0.name) }
        // With few palettes enabled the recency rule can exclude everything;
        // relax it rather than getting stuck on one color.
        if candidates.isEmpty {
            candidates = enabled.filter { $0 != current }
        }
        return candidates.randomElement(using: &generator) ?? current
    }

    /// Begin a cross-fade to `palette`.
    public func transition(to palette: Palette, at now: TimeInterval) {
        guard palette != current else { return }
        previous = colorsAreMidTransition(at: now) ? blendedPalette(at: now) : current
        current = palette
        transitionStartedAt = now

        recent.append(currentIndex)
        if recent.count > PaletteController.recentMemory {
            recent.removeFirst(recent.count - PaletteController.recentMemory)
        }
    }

    /// 0 while a transition is running, 1 once it has finished.
    public func transitionProgress(at now: TimeInterval) -> Double {
        guard let start = transitionStartedAt else { return 1 }
        let elapsed = now - start
        guard elapsed < transitionDuration else { return 1 }
        return max(0, elapsed / transitionDuration)
    }

    private func colorsAreMidTransition(at now: TimeInterval) -> Bool {
        transitionProgress(at: now) < 1
    }

    /// The colors to upload this frame, interpolated in linear RGB.
    public func colors(at now: TimeInterval)
        -> (a: SIMD3<Float>, b: SIMD3<Float>, glow: SIMD3<Float>) {
        let t = Float(transitionProgress(at: now))
        guard t < 1, let previous else {
            return (current.colorA, current.colorB, current.colorGlow)
        }
        // Smoothstep rather than linear, so the fade has no visible start or
        // stop edge.
        let e = t * t * (3 - 2 * t)
        return (mix(previous.colorA, current.colorA, e),
                mix(previous.colorB, current.colorB, e),
                mix(previous.colorGlow, current.colorGlow, e))
    }

    private func blendedPalette(at now: TimeInterval) -> Palette {
        // Interrupting a transition: freeze the current blend as the new
        // starting point so the next fade begins from what is on screen,
        // rather than snapping back to a color nobody is looking at.
        let c = colors(at: now)
        return Palette(name: "\(current.name) (blend)",
                       colorA: c.a, colorB: c.b, colorGlow: c.glow)
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
