import XCTest
@testable import NimbusKit

final class AnimatorTests: XCTestCase {

    func testIdleBeforeAnyFlare() {
        let a = Animator(idleIntensity: 0.30, flareDuration: 2.5)
        XCTAssertEqual(a.intensity(at: 100), 0.30, accuracy: 1e-5)
        XCTAssertFalse(a.isFlaring(at: 100))
    }

    func testFlarePeaksAtFullBrightnessThenSettlesToIdle() {
        let a = Animator(idleIntensity: 0.30, flareDuration: 2.5)
        a.flare(at: 0)
        XCTAssertEqual(a.intensity(at: 0), 1.0, accuracy: 1e-5)
        // 95% spent by the end of the flare, and exactly idle after it.
        XCTAssertEqual(a.intensity(at: 2.5), 0.30, accuracy: 1e-5)
        XCTAssertEqual(a.intensity(at: 10), 0.30, accuracy: 1e-5)
    }

    func testDecayIsMonotonicAndNeverDipsBelowIdle() {
        let a = Animator(idleIntensity: 0.30, flareDuration: 2.5)
        a.flare(at: 0)
        var previous = Float(2)
        for step in 0...50 {
            let value = a.intensity(at: Double(step) / 20.0)
            XCTAssertLessThanOrEqual(value, previous + 1e-6, "intensity must never rise mid-decay")
            XCTAssertGreaterThanOrEqual(value, 0.30 - 1e-6, "must never dim below the idle baseline")
            previous = value
        }
    }

    /// Width and speed must relax on the same curve as brightness, or the ring
    /// finishes brightening before it finishes shrinking and looks disjointed.
    func testWidthAndSpeedRelaxOnTheSameCurve() {
        let a = Animator(idleIntensity: 0.30, flareDuration: 2.5)
        a.flare(at: 0)
        XCTAssertEqual(a.bandScale(at: 0), 1.6, accuracy: 1e-5)
        XCTAssertEqual(a.speedScale(at: 0), 1.8, accuracy: 1e-5)
        XCTAssertEqual(a.bandScale(at: 2.5), 1.0, accuracy: 1e-5)
        XCTAssertEqual(a.speedScale(at: 2.5), 1.0, accuracy: 1e-5)
    }

    func testRefaringMidDecayRestartsAtFullBrightness() {
        let a = Animator(idleIntensity: 0.30, flareDuration: 2.5)
        a.flare(at: 0)
        XCTAssertLessThan(a.intensity(at: 1.0), 1.0)
        a.flare(at: 1.0)
        XCTAssertEqual(a.intensity(at: 1.0), 1.0, accuracy: 1e-5,
                       "switching windows again mid-settle must give a full pulse")
    }

    /// A user could set the flare to zero; it must degrade to a steady ring
    /// rather than divide by zero.
    func testZeroFlareDurationIsSafe() {
        let a = Animator(idleIntensity: 0.4, flareDuration: 0)
        a.flare(at: 0)
        XCTAssertEqual(a.intensity(at: 0), 0.4, accuracy: 1e-5)
        XCTAssertTrue(a.intensity(at: 1).isFinite)
    }
}

final class PaletteControllerTests: XCTestCase {

    /// Deterministic generator so the selection rules can be asserted.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testNeverPicksTheCurrentPalette() {
        var rng = SeededGenerator(state: 42)
        let c = PaletteController()
        for _ in 0..<200 {
            let next = c.pickNext(using: &rng)
            XCTAssertNotEqual(next, c.current)
            c.transition(to: next, at: 0)
        }
    }

    func testNeverRepeatsWithinTheRecentWindow() {
        var rng = SeededGenerator(state: 7)
        let c = PaletteController()
        var seen: [String] = [c.current.name]
        for step in 0..<200 {
            let next = c.pickNext(using: &rng)
            let window = seen.suffix(PaletteController.recentMemory)
            XCTAssertFalse(window.contains(next.name),
                           "\(next.name) repeated within the last \(PaletteController.recentMemory)")
            c.transition(to: next, at: Double(step) * 100)
            seen.append(next.name)
        }
    }

    /// With almost everything disabled the recency rule cannot be satisfied.
    /// It must relax rather than deadlock on a single color forever.
    func testRelaxesRecencyRuleWhenFewPalettesAreEnabled() {
        var rng = SeededGenerator(state: 99)
        let c = PaletteController()
        let disabled = Set(Palette.all.dropFirst(2).map(\.name))
        for step in 0..<20 {
            let next = c.pickNext(excluding: disabled, using: &rng)
            XCTAssertNotEqual(next, c.current, "must still alternate between the two enabled palettes")
            c.transition(to: next, at: Double(step))
        }
    }

    func testSingleEnabledPaletteDoesNotCrash() {
        var rng = SeededGenerator(state: 1)
        let c = PaletteController()
        let disabled = Set(Palette.all.dropFirst(1).map(\.name))
        XCTAssertEqual(c.pickNext(excluding: disabled, using: &rng).name, Palette.all[0].name)
    }

    func testCrossFadeStartsAtTheOldColourAndEndsAtTheNew() {
        let c = PaletteController()
        let from = c.current
        let to = Palette.all[4]
        c.transition(to: to, at: 1000)

        let atStart = c.colors(at: 1000)
        XCTAssertEqual(atStart.a.x, from.colorA.x, accuracy: 1e-4)

        let atEnd = c.colors(at: 1000 + c.transitionDuration)
        XCTAssertEqual(atEnd.a.x, to.colorA.x, accuracy: 1e-4)
        XCTAssertEqual(atEnd.b.y, to.colorB.y, accuracy: 1e-4)
    }

    func testMidFadeIsBetweenTheTwoColoursAndNeverACut() {
        let c = PaletteController()
        let from = c.current
        let to = Palette.all[4]
        c.transition(to: to, at: 0)

        let mid = c.colors(at: c.transitionDuration / 2)
        let lo = min(from.colorA.z, to.colorA.z)
        let hi = max(from.colorA.z, to.colorA.z)
        XCTAssertGreaterThanOrEqual(mid.a.z, lo - 1e-4)
        XCTAssertLessThanOrEqual(mid.a.z, hi + 1e-4)
    }
}
