import XCTest
import simd
@testable import FocusRingKit

final class PaletteTests: XCTestCase {

    func testPaletteListMatchesTheSpec() {
        XCTAssertEqual(Palette.all.count, 10)
        XCTAssertEqual(Palette.all.first?.name, "Ember")
        XCTAssertEqual(Set(Palette.all.map(\.name)).count, 10, "palette names must be unique")
    }

    /// Endpoints and the midpoint of the sRGB transfer curve. A common mistake
    /// is a plain 2.2 power, which is wrong near black and shifts every colour.
    func testSRGBToLinearEndpointsAndKnee() {
        XCTAssertEqual(Palette.srgbToLinear(0), 0, accuracy: 1e-6)
        XCTAssertEqual(Palette.srgbToLinear(1), 1, accuracy: 1e-6)
        // Below the knee the curve is a straight line, not a power.
        XCTAssertEqual(Palette.srgbToLinear(0.04), 0.04 / 12.92, accuracy: 1e-6)
        // Mid grey: 0.5 sRGB is ~0.214 linear, distinctly not 0.5.
        XCTAssertEqual(Palette.srgbToLinear(0.5), 0.2140, accuracy: 1e-3)
    }

    func testChannelOrderIsRGBNotBGR() {
        // Pure red: full in x, zero in y and z. Catches a swapped byte shift.
        let red = Palette.linear(from: 0xFF0000)
        XCTAssertEqual(red.x, 1, accuracy: 1e-5)
        XCTAssertEqual(red.y, 0, accuracy: 1e-5)
        XCTAssertEqual(red.z, 0, accuracy: 1e-5)

        let blue = Palette.linear(from: 0x0000FF)
        XCTAssertEqual(blue.z, 1, accuracy: 1e-5)
        XCTAssertEqual(blue.x, 0, accuracy: 1e-5)
    }

    func testEveryPaletteIsBrightEnoughToWinAgainstContent() {
        for palette in Palette.all {
            for color in [palette.colorA, palette.colorB, palette.colorGlow] {
                let peak = max(color.x, max(color.y, color.z))
                XCTAssertGreaterThan(peak, 0.4,
                                     "\(palette.name) has a channel peak too dim to read as a light source")
            }
        }
    }
}
