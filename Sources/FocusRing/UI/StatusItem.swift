import AppKit
import FocusRingKit

/// The menu bar icon and its menu (§9). Milestones fill this in; M0 needs only
/// enough to see the app is alive, read the permission state, and quit.
final class StatusItem: NSObject, NSMenuDelegate {

    private let item: NSStatusItem
    private let prefs: Preferences

    /// Set by AppDelegate; reflected in the menu each time it opens.
    var isTrusted: Bool = false

    var onToggleEnabled: (() -> Void)?
    var onGrantPermission: (() -> Void)?
    var onQuit: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            // A template image so it tracks light/dark menu bars automatically.
            let image = NSImage(systemSymbolName: "circle.dashed",
                                accessibilityDescription: "FocusRing")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt on open rather than mutated in place: the menu is small, and
    /// rebuilding keeps every item's state derived from one source of truth.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !isTrusted {
            let warning = NSMenuItem(title: "Accessibility permission needed",
                                     action: #selector(grantPermission),
                                     keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(title: "Enabled",
                                 action: #selector(toggleEnabled),
                                 keyEquivalent: "")
        enabled.target = self
        enabled.state = prefs.enabled ? .on : .off
        // Without permission the toggle is meaningless, so say so by disabling it.
        enabled.isEnabled = isTrusted
        menu.addItem(enabled)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit FocusRing",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func grantPermission() { onGrantPermission?() }
    @objc private func quit() { onQuit?() }
}
