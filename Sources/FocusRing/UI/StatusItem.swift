import AppKit
import ServiceManagement
import FocusRingKit

/// The menu bar icon and its menu (§9).
///
/// Every visual property of the ring is adjustable here. "Unmissable" is
/// genuinely personal — what reads as a helpful marker to one person reads as a
/// distraction to another — and all of these are plain uniform values, so
/// changing them costs nothing at runtime.
final class StatusItem: NSObject, NSMenuDelegate {

    private let item: NSStatusItem
    private let prefs: Preferences

    /// Set by AppDelegate; reflected in the menu each time it opens.
    var isTrusted: Bool = false
    var currentPaletteName: String = ""
    var frontmostBundleID: String?

    var onSettingsChanged: (() -> Void)?
    var onGrantPermission: (() -> Void)?
    var onNextColor: (() -> Void)?
    var onQuit: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            // A template image so it tracks light and dark menu bars.
            let image = NSImage(systemSymbolName: "circle.dashed",
                                accessibilityDescription: "FocusRing")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    // MARK: - Menu construction

    /// Rebuilt on every open rather than mutated in place: the menu is small,
    /// and rebuilding keeps every item's state derived from the preferences
    /// rather than from a parallel copy that can drift out of step.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard isTrusted else {
            let warning = item(title: "Accessibility permission needed…",
                               action: #selector(grantPermission))
            menu.addItem(warning)
            menu.addItem(.separator())
            menu.addItem(item(title: "Quit FocusRing", action: #selector(quit), key: "q"))
            return
        }

        let enabled = item(title: "Enabled", action: #selector(toggleEnabled))
        enabled.state = prefs.enabled ? .on : .off
        menu.addItem(enabled)

        let next = item(title: currentPaletteName.isEmpty
                        ? "Next colour now"
                        : "Next colour now (\(currentPaletteName))",
                        action: #selector(nextColor))
        next.isEnabled = prefs.enabled
        menu.addItem(next)

        menu.addItem(.separator())

        menu.addItem(submenu: intensityMenu(), title: "Brightness", in: self)
        menu.addItem(submenu: bandWidthMenu(), title: "Ring width", in: self)
        menu.addItem(submenu: motionSpeedMenu(), title: "Motion speed", in: self)
        menu.addItem(submenu: turbulenceMenu(), title: "Motion style", in: self)
        menu.addItem(submenu: flareMenu(), title: "Flare on switch", in: self)
        menu.addItem(submenu: frameRateMenu(), title: "Frame rate", in: self)
        menu.addItem(submenu: rotationMenu(), title: "Change colour every", in: self)

        menu.addItem(.separator())

        let hideFullScreen = item(title: "Hide in full screen",
                                  action: #selector(toggleHideInFullScreen))
        hideFullScreen.state = prefs.hideInFullScreen ? .on : .off
        menu.addItem(hideFullScreen)

        let hideDragging = item(title: "Hide while dragging",
                                action: #selector(toggleHideWhileDragging))
        hideDragging.state = prefs.hideWhileDragging ? .on : .off
        menu.addItem(hideDragging)

        menu.addItem(.separator())

        if let bundleID = frontmostBundleID, !prefs.exclusions.contains(bundleID) {
            menu.addItem(item(title: "Never ring \(shortName(for: bundleID))",
                              action: #selector(excludeFrontmost)))
        }
        if prefs.exclusions.isEmpty {
            let empty = NSMenuItem(title: "No excluded apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(submenu: exclusionsMenu(), title: "Excluded apps", in: self)
        }

        menu.addItem(.separator())

        let login = item(title: "Open at Login", action: #selector(toggleOpenAtLogin))
        login.state = prefs.openAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(item(title: "Quit FocusRing", action: #selector(quit), key: "q"))
    }

    // MARK: - Submenus

    private func intensityMenu() -> NSMenu {
        // Maps to idleIntensity: the brightness the ring settles to, not the
        // brightness of the flare, which is always full.
        options([("Subtle", 0.18), ("Normal", 0.30), ("Loud", 0.50)],
                isChosen: { abs(self.prefs.idleIntensity - $0) < 0.001 },
                apply: { self.prefs.idleIntensity = $0 })
    }

    private func bandWidthMenu() -> NSMenu {
        options(Preferences.BandWidth.allCases.map { ($0.rawValue.capitalized, $0) },
                isChosen: { self.prefs.bandWidth == $0 },
                apply: { self.prefs.bandWidth = $0 })
    }

    private func motionSpeedMenu() -> NSMenu {
        options(Preferences.MotionSpeed.allCases.map { ($0.title, $0) },
                isChosen: { self.prefs.motionSpeed == $0 },
                apply: { self.prefs.motionSpeed = $0 })
    }

    private func turbulenceMenu() -> NSMenu {
        options(Preferences.Turbulence.allCases.map { ($0.title, $0) },
                isChosen: { self.prefs.turbulence == $0 },
                apply: { self.prefs.turbulence = $0 })
    }

    private func flareMenu() -> NSMenu {
        options([("Off", 0.0), ("Quick (1.5s)", 1.5), ("Normal (2.5s)", 2.5), ("Long (5s)", 5.0)],
                isChosen: { abs(self.prefs.flareDuration - $0) < 0.001 },
                apply: { self.prefs.flareDuration = $0 })
    }

    private func frameRateMenu() -> NSMenu {
        options([("30 fps", 30), ("60 fps", 60)],
                isChosen: { self.prefs.frameRate == $0 },
                apply: { self.prefs.frameRate = $0 })
    }

    private func exclusionsMenu() -> NSMenu {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "Click an app to start ringing it again",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        for bundleID in prefs.exclusions.sorted() {
            let entry = NSMenuItem(title: shortName(for: bundleID),
                                   action: #selector(removeExclusion(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.toolTip = bundleID
            entry.representedObject = bundleID
            menu.addItem(entry)
        }
        return menu
    }

    private func rotationMenu() -> NSMenu {
        options([("10 minutes", 600.0), ("30 minutes", 1800.0),
                 ("1 hour", 3600.0), ("Never", 0.0)],
                isChosen: { abs(self.prefs.paletteInterval - $0) < 0.001 },
                apply: { self.prefs.paletteInterval = $0 })
    }

    /// Builds a radio-style submenu from a list of labelled values. Each item
    /// carries its value in `representedObject`, so there is one code path for
    /// reading the choice back regardless of the value's type.
    private func options<T>(_ choices: [(String, T)],
                            isChosen: (T) -> Bool,
                            apply: @escaping (T) -> Void) -> NSMenu {
        let menu = NSMenu()
        for (title, value) in choices {
            let entry = NSMenuItem(title: title,
                                   action: #selector(chooseOption(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = isChosen(value) ? .on : .off
            entry.representedObject = Option(apply: { apply(value) })
            menu.addItem(entry)
        }
        return menu
    }

    /// Boxes the setter so any value type can ride in `representedObject`.
    private final class Option: NSObject {
        let apply: () -> Void
        init(apply: @escaping () -> Void) { self.apply = apply }
    }

    // MARK: - Helpers

    private func item(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func shortName(for bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }

    // MARK: - Actions

    @objc private func chooseOption(_ sender: NSMenuItem) {
        (sender.representedObject as? Option)?.apply()
        onSettingsChanged?()
    }

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
        onSettingsChanged?()
    }

    @objc private func toggleHideInFullScreen() {
        prefs.hideInFullScreen.toggle()
        onSettingsChanged?()
    }

    @objc private func toggleHideWhileDragging() {
        prefs.hideWhileDragging.toggle()
        onSettingsChanged?()
    }

    @objc private func excludeFrontmost() {
        guard let bundleID = frontmostBundleID else { return }
        prefs.exclusions.insert(bundleID)
        onSettingsChanged?()
    }

    @objc private func toggleOpenAtLogin() {
        let wanted = !prefs.openAtLogin
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            prefs.openAtLogin = wanted
        } catch {
            // Registration fails for an unsigned or relocated bundle. Report it
            // rather than leaving a checkmark that does nothing.
            Log.write("Open at Login \(wanted ? "registration" : "removal") failed: \(error)")
            prefs.openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @objc private func removeExclusion(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        prefs.exclusions.remove(bundleID)
        onSettingsChanged?()
    }

    @objc private func nextColor() { onNextColor?() }
    @objc private func grantPermission() { onGrantPermission?() }
    @objc private func quit() { onQuit?() }
}

private extension NSMenu {
    /// Attaches a submenu under a parent item in one line, keeping
    /// `menuNeedsUpdate` readable as a list of what the menu contains.
    func addItem(submenu: NSMenu, title: String, in target: AnyObject) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        addItem(parent)
    }
}
