import CoreGraphics

/// A snapshot of what currently has keyboard focus. `frame` is **already in
/// AppKit screen coordinates** — nothing downstream of the tracker should ever
/// see an AX rect.
public struct FocusState: Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let windowID: CGWindowID?
    public let frame: CGRect
    public let isFullScreen: Bool

    public init(pid: pid_t,
                bundleID: String?,
                windowID: CGWindowID?,
                frame: CGRect,
                isFullScreen: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.windowID = windowID
        self.frame = frame
        self.isFullScreen = isFullScreen
    }

    /// A focus *change* worth flaring for, as opposed to the same window being
    /// dragged or resized. The flare must not re-fire on every move event.
    public func isDifferentWindow(from other: FocusState?) -> Bool {
        guard let other else { return true }
        if pid != other.pid { return true }
        if let a = windowID, let b = other.windowID { return a != b }
        // Without a window ID, a jump in position is the only signal we have
        // that this is a different window rather than the same one moving.
        return frame.origin.distance(to: other.frame.origin) > 4
            || abs(frame.width - other.frame.width) > 4
            || abs(frame.height - other.frame.height) > 4
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
