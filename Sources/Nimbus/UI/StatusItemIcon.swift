import AppKit

/// The menu bar mark, drawn rather than shipped as an asset.
///
/// Menu bar icons are *template* images: macOS keeps only the alpha channel and
/// tints the result for the current menu bar, so no color or gradient from the
/// actual ring can survive here. Only silhouette does, at around 18pt. Hence a
/// window outline ringed by a broken band — the break-up is what the real ring
/// looks like when the turbulence thins it, and it is also what keeps the mark
/// from reading as a progress spinner.
///
/// Drawn with a handler rather than rasterized once, so it is re-rendered at
/// whatever backing scale the menu bar's display happens to have.
enum StatusItemIcon {

    static func make(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false) { _ in
            draw(size)
            return true
        }
        // Tells AppKit to tint it for light and dark menu bars automatically.
        image.isTemplate = true
        return image
    }

    private static func draw(_ s: CGFloat) {
        NSColor.black.setStroke()

        let center = CGPoint(x: s / 2, y: s / 2)
        let rect = CGRect(x: center.x - s * 0.20, y: center.y - s * 0.15,
                          width: s * 0.40, height: s * 0.30)
        let radius = s * 0.06

        let window = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        window.lineWidth = s * 0.085
        window.stroke()

        // Far enough out that the two never merge into a blob at small sizes —
        // the failure mode every tighter version of this had.
        let spread = s * 0.155
        let band = NSBezierPath(roundedRect: rect.insetBy(dx: -spread, dy: -spread),
                                xRadius: radius + spread,
                                yRadius: radius + spread)
        band.lineWidth = s * 0.062
        band.lineCapStyle = .round
        // Deliberately uneven, mirroring the ring's own broken-up look.
        var pattern: [CGFloat] = [0.16, 0.115, 0.075, 0.10, 0.21, 0.105].map { $0 * s }
        band.setLineDash(&pattern, count: pattern.count, phase: 0)
        band.stroke()
    }
}
