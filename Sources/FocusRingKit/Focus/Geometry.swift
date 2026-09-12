import CoreGraphics

/// Conversion between the two coordinate systems this app straddles.
///
/// The Accessibility API reports **global coordinates with the origin at the
/// top-left of the primary display, y growing downward**. AppKit uses a
/// **bottom-left origin with y growing upward**, also relative to the primary
/// display. Every AX rect must pass through `axToScreen` before it touches an
/// `NSWindow`.
///
/// `primaryHeight` is injected rather than read from `NSScreen` so the math is
/// testable without a display attached, and so callers are forced to re-read it
/// after `didChangeScreenParametersNotification` instead of caching it.
public enum Geometry {

    /// Flip an AX rect into AppKit screen coordinates.
    ///
    /// - Parameter primaryHeight: height of `NSScreen.screens[0]`, the screen
    ///   owning the menu bar. Must be re-read on every screen-parameter change.
    public static func axToScreen(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.origin.x,
               y: primaryHeight - r.origin.y - r.height,
               width: r.width,
               height: r.height)
    }

    /// Inverse of `axToScreen`. The transform is its own inverse, but naming
    /// both directions keeps call sites honest about which way they are going.
    public static func screenToAX(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        axToScreen(r, primaryHeight: primaryHeight)
    }

    /// Frames this absurd are always a misreporting app, never a real window.
    /// §10: reject and hide rather than drawing a ring around nonsense.
    public static let minSensibleSide: CGFloat = 40
    public static let maxSensibleSide: CGFloat = 20_000

    public static func isSensible(_ r: CGRect) -> Bool {
        guard r.width.isFinite, r.height.isFinite,
              r.origin.x.isFinite, r.origin.y.isFinite else { return false }
        return r.width  >= minSensibleSide && r.width  <= maxSensibleSide
            && r.height >= minSensibleSide && r.height <= maxSensibleSide
    }

    /// The overlay frame: the window rect grown by `margin` on all sides, then
    /// clipped to the union of all screens so it can never be placed off-desktop.
    public static func overlayFrame(for window: CGRect,
                                    margin: CGFloat,
                                    screenUnion: CGRect) -> CGRect {
        let outset = window.insetBy(dx: -margin, dy: -margin)
        return outset.intersection(screenUnion)
    }

    /// Band widths must not swallow a small window whole (§10).
    public static func clampedBand(inner: CGFloat,
                                   outer: CGFloat,
                                   window: CGRect) -> (inner: CGFloat, outer: CGFloat) {
        let limit = min(window.width, window.height) / 4
        return (min(inner, limit), min(outer, limit))
    }
}
