import AppKit

/// A borderless, click-through window that sits above normal windows and can
/// never take focus — which matters more than usual here, since an overlay that
/// stole focus would corrupt the very thing it is reporting.
final class OverlayWindow: NSWindow {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit otherwise nudges a window down so it cannot sit beneath the menu
    /// bar. For a tracking overlay that is silent corruption: the frame shifts
    /// on the y axis only, so the left and right edges look perfect while the
    /// top and bottom sit off the window. The overlay is positioned from real
    /// window geometry and must be placed exactly where it is told.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Critical: the overlay covers the focused window's edges, so anything
        // other than full pass-through would swallow real clicks.
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        // No implicit fade on orderFront; the ring must appear instantly on a
        // focus change or the flare is wasted.
        animationBehavior = .none
        displaysWhenScreenProfileChanges = true
    }
}
