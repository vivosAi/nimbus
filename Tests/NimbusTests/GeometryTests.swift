import XCTest
import CoreGraphics
@testable import NimbusKit

/// §6.4 calls coordinate conversion "the single most common source of bugs in
/// this kind of app", and the cases that break naive implementations — a display
/// above or to the left of the primary — are tedious to reproduce by hand.
/// They are trivial here.
final class GeometryTests: XCTestCase {

    /// A 1080p primary display, for legible arithmetic.
    let primary: CGFloat = 1080

    func testWindowOnPrimaryFlipsAboutPrimaryHeight() {
        let ax = CGRect(x: 100, y: 50, width: 800, height: 600)
        let screen = Geometry.axToScreen(ax, primaryHeight: primary)
        // Top edge sits 50pt below the top of a 1080pt screen, so the bottom
        // edge is at 1080 - 50 - 600 = 430.
        XCTAssertEqual(screen, CGRect(x: 100, y: 430, width: 800, height: 600))
    }

    func testWindowFlushToTopLeftOfPrimary() {
        let ax = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen = Geometry.axToScreen(ax, primaryHeight: primary)
        XCTAssertEqual(screen, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    /// A display mounted ABOVE the primary reports negative AX y. In AppKit the
    /// window must land above the primary's top edge, i.e. y > primaryHeight.
    func testDisplayAbovePrimaryProducesCoordinatesAbovePrimary() {
        let ax = CGRect(x: 200, y: -900, width: 1280, height: 800)
        let screen = Geometry.axToScreen(ax, primaryHeight: primary)
        XCTAssertEqual(screen.origin.y, 1080 - (-900) - 800)  // 1180
        XCTAssertGreaterThan(screen.origin.y, primary,
                             "a window on a display above the primary must sit above it in AppKit space")
    }

    /// A display mounted to the LEFT reports negative AX x, which passes through
    /// untouched — only the y axis flips.
    func testDisplayLeftOfPrimaryKeepsNegativeX() {
        let ax = CGRect(x: -1920, y: 100, width: 1600, height: 900)
        let screen = Geometry.axToScreen(ax, primaryHeight: primary)
        XCTAssertEqual(screen.origin.x, -1920)
        XCTAssertEqual(screen.origin.y, 1080 - 100 - 900)  // 80
    }

    /// Above AND to the left at once: both axes exercised together.
    func testDisplayAboveAndLeftOfPrimary() {
        let ax = CGRect(x: -2560, y: -1400, width: 1200, height: 700)
        let screen = Geometry.axToScreen(ax, primaryHeight: primary)
        XCTAssertEqual(screen, CGRect(x: -2560, y: 1780, width: 1200, height: 700))
    }

    func testConversionRoundTrips() {
        let ax = CGRect(x: -640, y: -220, width: 1024, height: 768)
        let back = Geometry.screenToAX(Geometry.axToScreen(ax, primaryHeight: primary),
                                       primaryHeight: primary)
        XCTAssertEqual(back, ax)
    }

    // MARK: - Sanity filtering (§10)

    func testRejectsDegenerateAndAbsurdFrames() {
        XCTAssertFalse(Geometry.isSensible(.zero))
        XCTAssertFalse(Geometry.isSensible(CGRect(x: 0, y: 0, width: 39, height: 400)))
        XCTAssertFalse(Geometry.isSensible(CGRect(x: 0, y: 0, width: 400, height: 39)))
        XCTAssertFalse(Geometry.isSensible(CGRect(x: 0, y: 0, width: 50_000, height: 400)))
        XCTAssertFalse(Geometry.isSensible(CGRect(x: CGFloat.nan, y: 0, width: 400, height: 400)))
        XCTAssertFalse(Geometry.isSensible(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400)))
    }

    func testAcceptsOrdinaryAndOffscreenNegativeFrames() {
        XCTAssertTrue(Geometry.isSensible(CGRect(x: 0, y: 0, width: 1440, height: 900)))
        XCTAssertTrue(Geometry.isSensible(CGRect(x: -1920, y: -1080, width: 800, height: 600)))
    }

    // MARK: - Overlay framing

    func testOverlayIsOutsetByMargin() {
        let window = CGRect(x: 500, y: 400, width: 800, height: 600)
        let huge = CGRect(x: -10_000, y: -10_000, width: 40_000, height: 40_000)
        let overlay = Geometry.overlayFrame(for: window, margin: 24, screenUnion: huge)
        XCTAssertEqual(overlay, CGRect(x: 476, y: 376, width: 848, height: 648))
    }

    func testOverlayIsClippedToScreenUnion() {
        // Window flush against the left edge of the desktop: the outset would
        // push the overlay off-desktop, so it must be clipped back.
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let union = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let overlay = Geometry.overlayFrame(for: window, margin: 24, screenUnion: union)
        XCTAssertEqual(overlay, CGRect(x: 0, y: 0, width: 824, height: 624))
    }

    // MARK: - Band clamping (§10)

    func testBandClampsOnWindowsSmallerThanTheBand() {
        let tiny = CGRect(x: 0, y: 0, width: 60, height: 60)
        let (inner, outer) = Geometry.clampedBand(inner: 6, outer: 18, window: tiny)
        XCTAssertEqual(inner, 6, "6pt already fits inside 60/4 = 15")
        XCTAssertEqual(outer, 15, "18pt must clamp to min(w,h)/4")
    }

    func testBandIsUntouchedOnOrdinaryWindows() {
        let normal = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let (inner, outer) = Geometry.clampedBand(inner: 6, outer: 18, window: normal)
        XCTAssertEqual(inner, 6)
        XCTAssertEqual(outer, 18)
    }
}

/// The uniform block is shared with `Shaders.metal` by hand. If this ever fails,
/// the shader is reading garbage and the ring will render wrong with no compiler
/// complaint on either side.
final class UniformsLayoutTests: XCTestCase {

    func testStrideMatchesTheMetalStruct() {
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, Uniforms.expectedStride)
    }

    func testFieldOffsetsAreSixteenByteAlignedWhereMetalRequiresIt() {
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.resolution), 0)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.windowRect), 16)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.colorA), 32)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.colorB), 48)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.colorGlow), 64)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.params0), 80)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.params1), 96)
    }

    func testPackedAccessorsWriteThroughToTheRightLanes() {
        var u = Uniforms()
        u.cornerRadius = 11; u.bandInner = 6; u.bandOuter = 18; u.flowPhase = 1.5
        u.intensity = 0.3; u.warpPhase = 0.5; u.noiseScale = 2.5; u.glowFalloff = 12
        XCTAssertEqual(u.params0, SIMD4<Float>(11, 6, 18, 1.5))
        XCTAssertEqual(u.params1, SIMD4<Float>(0.3, 0.5, 2.5, 12))
    }
}
