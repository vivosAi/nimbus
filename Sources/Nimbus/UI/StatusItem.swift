import AppKit
import ServiceManagement
import NimbusKit

/// The menu bar icon and its menu.
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
    var onShowAbout: (() -> Void)?
    var onChooseColor: ((Palette) -> Void)?
    var onQuit: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = StatusItemIcon.make()
            button.image?.accessibilityDescription = "Nimbus"
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
            menu.addItem(item(title: "Quit Nimbus", action: #selector(quit), key: "q"))
            return
        }

        let enabled = item(title: "Enabled", action: #selector(toggleEnabled))
        enabled.state = prefs.enabled ? .on : .off
        menu.addItem(enabled)

        // Deliberately not "Next color now (Aurora)": that reads as a promise
        // about the *next* color when it was naming the current one. The
        // current palette belongs on the Color item, where the checkmark
        // already agrees with it.
        let next = item(title: "Next color now", action: #selector(nextColor))
        next.isEnabled = prefs.enabled
        menu.addItem(next)

        menu.addItem(submenu: colorMenu(),
                     title: currentPaletteName.isEmpty ? "Color" : "Color: \(currentPaletteName)",
                     in: self)

        menu.addItem(.separator())

        menu.addItem(submenu: intensityMenu(), title: "Brightness", in: self)
        menu.addItem(submenu: bandWidthMenu(), title: "Ring width", in: self)
        menu.addItem(submenu: motionSpeedMenu(), title: "Motion speed", in: self)
        menu.addItem(submenu: turbulenceMenu(), title: "Motion style", in: self)
        menu.addItem(submenu: flareMenu(), title: "Flare on switch", in: self)
        menu.addItem(submenu: frameRateMenu(), title: "Frame rate", in: self)
        menu.addItem(submenu: rotationMenu(), title: "Change color every", in: self)
        menu.addItem(submenu: idleMenu(), title: "When you are away", in: self)

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

        menu.addItem(.separator())

        // One item, not three. The version and the links live behind it: this
        // menu exists so people can change a setting, and anything asking
        // something of them here is in the way.
        menu.addItem(item(title: "About Nimbus", action: #selector(showAbout)))

        menu.addItem(item(title: "Quit Nimbus", action: #selector(quit), key: "q"))
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

    /// Frames are the entire cost of running the ring — roughly 0.1% of a CPU
    /// core per frame-per-second, essentially regardless of what the shader
    /// does. These are the peak rate, used while a flare is moving quickly; the
    /// ring halves it once it settles into its slow drift, where the difference
    /// cannot be seen.
    private func frameRateMenu() -> NSMenu {
        options([("Battery saver (15)", 15), ("Normal (30)", 30), ("Smooth (60)", 60)],
                isChosen: { self.prefs.frameRate == $0 },
                apply: { self.prefs.frameRate = $0 })
    }

    /// Pick a palette directly. The checkmark is the one currently showing;
    /// choosing another cross-fades to it exactly as a timed rotation would,
    /// so a manual change never looks different from an automatic one.
    private func colorMenu() -> NSMenu {
        let menu = NSMenu()
        for palette in Palette.all {
            let entry = NSMenuItem(title: palette.name,
                                   action: #selector(chooseColor(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = palette.name == currentPaletteName ? .on : .off
            entry.representedObject = palette.name
            // A swatch, so the list can be read by color rather than by name.
            entry.image = StatusItem.swatch(for: palette)
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let rotation = NSMenuItem(title: "In rotation…", action: nil, keyEquivalent: "")
        rotation.submenu = rotationMembershipMenu()
        menu.addItem(rotation)
        return menu
    }

    /// Which palettes the timer is allowed to choose from. Separate from
    /// picking one now, because wanting to see a color is not the same as
    /// wanting it to keep coming back.
    private func rotationMembershipMenu() -> NSMenu {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "Colors the timer may choose from",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let disabled = prefs.disabledPalettes
        for palette in Palette.all {
            let entry = NSMenuItem(title: palette.name,
                                   action: #selector(toggleColorInRotation(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = disabled.contains(palette.name) ? .off : .on
            entry.representedObject = palette.name
            // Never let the user disable the last one; rotation needs somewhere
            // to go and an empty list would silently freeze the color.
            entry.isEnabled = disabled.contains(palette.name)
                || disabled.count < Palette.all.count - 1
            menu.addItem(entry)
        }
        return menu
    }

    /// A filled circle in the palette's own colors, converted back from the
    /// stored linear RGB for display.
    private static func swatch(for palette: Palette) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let color = NSColor(srgbRed: CGFloat(linearToSRGB(palette.colorA.x)),
                            green: CGFloat(linearToSRGB(palette.colorA.y)),
                            blue: CGFloat(linearToSRGB(palette.colorA.z)),
                            alpha: 1)
        let edge = NSColor(srgbRed: CGFloat(linearToSRGB(palette.colorB.x)),
                           green: CGFloat(linearToSRGB(palette.colorB.y)),
                           blue: CGFloat(linearToSRGB(palette.colorB.z)),
                           alpha: 1)
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        edge.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
        image.unlockFocus()
        return image
    }

    private static func linearToSRGB(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    /// What happens after a stretch with no input. The default keeps the ring
    /// on screen with its animation stopped, because the moment you walk back
    /// and look at the screens to see which one has keyboard focus is precisely
    /// when a hidden ring would be useless. Displays going to sleep is handled
    /// separately and always stops rendering — nobody can see it either way.
    private func idleMenu() -> NSMenu {
        let menu = NSMenu()
        for behavior in Preferences.IdleBehavior.allCases {
            let entry = NSMenuItem(title: behavior.title,
                                   action: #selector(chooseOption(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = prefs.idleBehavior == behavior ? .on : .off
            entry.representedObject = Option(apply: { self.prefs.idleBehavior = behavior })
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let after = NSMenuItem(title: "After…", action: nil, keyEquivalent: "")
        after.submenu = options([("2 minutes", 120.0), ("5 minutes", 300.0),
                                 ("10 minutes", 600.0), ("30 minutes", 1800.0),
                                 ("Never", 0.0)],
                                isChosen: { abs(self.prefs.idleThreshold - $0) < 0.001 },
                                apply: { self.prefs.idleThreshold = $0 })
        menu.addItem(after)

        menu.addItem(.separator())
        let flare = NSMenuItem(title: "Flare when you come back",
                               action: #selector(toggleFlareOnReturn),
                               keyEquivalent: "")
        flare.target = self
        flare.state = prefs.flareOnReturn ? .on : .off
        menu.addItem(flare)
        return menu
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

    /// Builds a radio-style submenu from a list of labeled values. Each item
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

    /// e.g. "0.1.0 (1)". Both come from Info.plist.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
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

    @objc private func toggleFlareOnReturn() {
        prefs.flareOnReturn.toggle()
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

    @objc private func chooseColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let palette = Palette.all.first(where: { $0.name == name }) else { return }
        onChooseColor?(palette)
    }

    @objc private func toggleColorInRotation(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var disabled = prefs.disabledPalettes
        if disabled.contains(name) { disabled.remove(name) } else { disabled.insert(name) }
        prefs.disabledPalettes = disabled
        onSettingsChanged?()
    }

    @objc private func showAbout() { onShowAbout?() }

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
