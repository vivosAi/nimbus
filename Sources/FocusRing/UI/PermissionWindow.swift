import AppKit

/// Shown once at first launch when Accessibility is not yet granted. It closes
/// itself the moment the grant lands, so the user never has to come back to it.
final class PermissionWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    var onOpenSettings: (() -> Void)?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "FocusRing"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "FocusRing needs Accessibility access")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: """
            It uses it only to read which window has keyboard focus, and where \
            that window is on screen.

            It never reads window contents, never records the screen, and never \
            touches the network.
            """)
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = 400

        let hint = NSTextField(labelWithString: "This window closes on its own once access is granted.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let button = NSButton(title: "Open System Settings",
                              target: self,
                              action: #selector(openSettings))
        button.keyEquivalent = "\r"

        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(hint)

        window.contentView = stack
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
