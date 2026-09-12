import AppKit

/// M2 placeholder content: a plain rounded stroke where the Metal ring will go.
/// Deliberately crude — its only job is to prove the overlay tracks the focused
/// window, passes clicks through, and never flickers. M3 replaces it.
final class BorderView: NSView {

    /// The tracked window's rect **in this view's coordinate space**. Passed
    /// explicitly rather than derived from a uniform inset, because the overlay
    /// gets clipped to the screen union and then the margin is no longer equal
    /// on all four sides. M3's shader needs the same value as a uniform.
    var windowRect: CGRect = .zero { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 11 { didSet { needsDisplay = true } }
    var strokeColor: NSColor = .systemPink { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 3
        // Stroke straddles the path, so shrink by half a line width to keep the
        // whole stroke on the window edge rather than half of it outside.
        let rect = windowRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect,
                                xRadius: cornerRadius,
                                yRadius: cornerRadius)
        path.lineWidth = lineWidth
        strokeColor.setStroke()
        path.stroke()
    }
}
