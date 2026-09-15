import ApplicationServices
import CoreGraphics

/// Thin, non-throwing wrappers over the Accessibility attribute API.
///
/// Every one of these is a synchronous IPC call into another process, so they
/// must never run on the main thread: a hung or busy app can make a single read
/// block for seconds. `AXUIElementSetMessagingTimeout` bounds the damage, but
/// the queue discipline is what actually keeps the UI alive.
enum AX {

    /// Applied to every element we create, windows included — not just app
    /// elements — because a stalled *window* read is exactly what strands the
    /// ring in the wrong place.
    static let messagingTimeout: Float = 0.25

    static func makeApplication(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, messagingTimeout)
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyValue(element, attribute) as? Bool
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyValue(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyValue(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Position and size in one call. Returns nil if either read fails, so a
    /// half-read window can never produce a half-correct rect.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute as String),
              let size = size(element, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Sheets and popovers must not steal the ring from the window they belong
    /// to, so walk up to the owning window.
    static func resolveToWindow(_ element: AXUIElement, maxDepth: Int = 6) -> AXUIElement? {
        var current = element
        for _ in 0..<maxDepth {
            let role = string(current, kAXRoleAttribute as String)
            if role == kAXWindowRole as String { return current }
            guard let parent = self.element(current, kAXParentAttribute as String) else { return nil }
            current = parent
        }
        return nil
    }
}
