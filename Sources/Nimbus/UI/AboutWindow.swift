import AppKit
import NimbusKit

/// A small About panel: what this is, which version, and a quiet line at the
/// bottom inviting you to get in touch.
///
/// Deliberately not in the main menu. Someone opening the menu wants to change
/// a setting; asking them to follow anyone at that moment turns a utility into
/// a funnel. People arrive here on purpose, which is the only place an
/// invitation reads as friendly rather than as marketing.
final class AboutWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    var onOpenURL: ((URL) -> Void)?

    private static let xURL = URL(string: "https://x.com/vivasonico")!
    private static let sourceURL = URL(string: "https://github.com/vivosAi/nimbus")!

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "About Nimbus"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 24, right: 30)

        if let icon = NSApp.applicationIconImage {
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 84).isActive = true
            view.heightAnchor.constraint(equalToConstant: 84).isActive = true
            stack.addArrangedSubview(view)
        }

        let name = NSTextField(labelWithString: "Nimbus")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(name)

        let version = NSTextField(labelWithString: "Version \(StatusItem.versionString)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)

        stack.setCustomSpacing(18, after: version)

        let blurb = NSTextField(wrappingLabelWithString: """
            macOS tells you which window has keyboard focus with a slightly \
            darker title bar. On a big screen, or several, that is invisible — \
            so you start typing and it goes somewhere you did not expect.

            Nimbus draws a ring of light around the focused window, so you \
            cannot miss it.
            """)
        blurb.font = .systemFont(ofSize: 12)
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = 350
        stack.addArrangedSubview(blurb)

        stack.setCustomSpacing(16, after: blurb)

        let promise = NSTextField(wrappingLabelWithString: """
            Free, open source, and it stays that way. It reads nothing but \
            window positions, and never touches the network.
            """)
        promise.font = .systemFont(ofSize: 11)
        promise.textColor = .secondaryLabelColor
        promise.alignment = .center
        promise.preferredMaxLayoutWidth = 350
        stack.addArrangedSubview(promise)

        stack.setCustomSpacing(20, after: promise)

        let hello = NSTextField(labelWithString: "Come say hello")
        hello.font = .systemFont(ofSize: 12)
        hello.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hello)

        let links = NSStackView(views: [
            linkButton("@vivasonico", action: #selector(openX)),
            linkButton("Source and issues", action: #selector(openSource)),
        ])
        links.orientation = .horizontal
        links.spacing = 18
        stack.addArrangedSubview(links)

        window.contentView = stack
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .linkColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.linkColor,
                         .font: NSFont.systemFont(ofSize: 12)])
        return button
    }

    func close() { window?.close() }

    @objc private func openX() { onOpenURL?(AboutWindow.xURL) }
    @objc private func openSource() { onOpenURL?(AboutWindow.sourceURL) }
}
