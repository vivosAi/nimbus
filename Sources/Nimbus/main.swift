import AppKit

// A menu-bar-only utility: no Dock icon, never becomes the active application,
// so it can never be the thing that steals the focus it is trying to report.
// `LSUIElement` in Info.plist covers the bundled case; this covers running the
// bare binary during development.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
