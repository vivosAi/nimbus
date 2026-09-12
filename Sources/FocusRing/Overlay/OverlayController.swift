import AppKit
import MetalKit
import FocusRingKit

/// Owns the single overlay window and decides when it is on screen and where.
///
/// The window is created once and reused for the lifetime of the app. Creating
/// a fresh window per focus change is the obvious implementation and it flickers
/// visibly on every switch.
final class OverlayController {

    private let prefs: Preferences
    private let window = OverlayWindow()

    private let metalView: MTKView?
    private let renderer: RingRenderer?
    /// §15's fallback when Metal cannot start, and — while `debugMode` is on —
    /// a control drawn *over* the Metal view. If the stroke appears and the
    /// Metal output does not, the overlay window is fine and the fault is in
    /// Metal presentation, not in window setup.
    private let borderView: BorderView?
    private let container = NSView()

    private(set) var isVisible = false
    private var lastState: FocusState?

    /// While the focused window is being dragged or resized the ring stands
    /// down (§6.5, amended). The last state is kept so it can be restored at
    /// the window's new resting position without waiting for a focus event.
    private var isSuppressedByMotion = false

    /// The last window a flare was fired for, so repeats are suppressed.
    private var lastFlaredState: FocusState?

    private var isIdle = false
    private var displaysAreAsleep = false

    init(prefs: Preferences) {
        self.prefs = prefs

        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        if let renderer = RingRenderer(view: view) {
            view.device = renderer.metalDevice
            view.delegate = renderer

            // Transparency: the window, its layer, and the clear colour all have
            // to agree, or the ring arrives inside an opaque black rectangle.
            view.wantsLayer = true
            view.layer?.isOpaque = false
            (view.layer as? CAMetalLayer)?.isOpaque = false
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = prefs.frameRate
            view.isPaused = true          // nothing to draw until a window is focused
            view.autoResizeDrawable = true

            // A CAMetalLayer has to live inside a layer-backed hierarchy to be
            // composited; a non-layer-backed ancestor can leave it orphaned.
            container.wantsLayer = true
            container.layer?.isOpaque = false

            let control = BorderView()
            control.strokeColor = .systemYellow
            control.isHidden = prefs.debugMode == 0

            container.addSubview(view)
            container.addSubview(control, positioned: .above, relativeTo: view)
            view.autoresizingMask = [.width, .height]
            control.autoresizingMask = [.width, .height]

            self.metalView = view
            self.renderer = renderer
            self.borderView = control
            window.contentView = container
            Log.write("Metal renderer ready")
        } else {
            // Rather than lose the app to a Metal problem, fall back to the
            // plain stroke. Less alive, but it always composites correctly.
            let fallback = BorderView()
            self.metalView = nil
            self.renderer = nil
            self.borderView = fallback
            container.addSubview(fallback)
            fallback.autoresizingMask = [.width, .height]
            window.contentView = container
            Log.write("Metal unavailable — falling back to the plain border")
        }
    }

    /// The overlay is hidden for the duration of a drag or resize, then
    /// restored once the window is at rest.
    func setInMotion(_ inMotion: Bool) {
        guard prefs.hideWhileDragging else { return }
        guard inMotion != isSuppressedByMotion else { return }
        isSuppressedByMotion = inMotion

        if inMotion {
            let state = lastState
            hide()
            lastState = state          // hide() clears it; we want it back after
        } else {
            update(with: lastState)
        }
    }

    /// The flare fires on a change to a *different* window, not on every
    /// geometry update — otherwise dragging or resizing would keep it lit and
    /// it would never settle.
    private func flareIfWindowChanged(to state: FocusState) {
        guard state.isDifferentWindow(from: lastFlaredState) else { return }
        lastFlaredState = state
        renderer?.animator.flare(at: CACurrentMediaTime())
    }

    /// Returning to the machine is exactly when you are most likely to type into
    /// the wrong window, so it gets the same pulse a focus change does.
    func flareNow() {
        renderer?.animator.flare(at: CACurrentMediaTime())
    }

    // MARK: - Palette

    var currentPalette: Palette { renderer?.paletteController.current ?? Palette.all[0] }
    var paletteIndex: Int { renderer?.paletteController.currentIndex ?? 0 }
    var paletteRecent: [Int] { renderer?.paletteController.recent ?? [] }

    func transitionPalette(to palette: Palette) {
        renderer?.paletteController.transition(to: palette, at: CACurrentMediaTime())
    }

    func pickNextPalette<G: RandomNumberGenerator>(excluding disabled: Set<String>,
                                                   using generator: inout G) -> Palette {
        renderer?.paletteController.pickNext(excluding: disabled, using: &generator)
            ?? Palette.all[0]
    }

    func restorePalette(index: Int, recent: [Int]) {
        renderer?.paletteController = PaletteController(startIndex: index, recent: recent)
    }

    // MARK: - Power

    /// Displays asleep: stop entirely, and order the window out so nothing is
    /// restored mid-frame when they wake.
    func setDisplaysAsleep(_ asleep: Bool) {
        displaysAreAsleep = asleep
        applyRenderingState()
    }

    /// The user has been away. What happens is their choice, but the default —
    /// and the only one that serves the case this app exists for — freezes the
    /// animation while leaving the ring on screen. A paused MTKView keeps its
    /// last frame, so this costs nothing and still answers "which window has
    /// keyboard focus?" for someone who has just walked back and is looking at
    /// the screen before touching anything.
    func setIdle(_ idle: Bool) {
        isIdle = idle
        applyRenderingState()
    }

    private func applyRenderingState() {
        guard let metalView else { return }

        if displaysAreAsleep {
            metalView.isPaused = true
            if isVisible { window.orderOut(nil) }
            return
        }

        // Coming back from display sleep: restore whatever should be showing.
        if isVisible, !window.isVisible { window.orderFront(nil) }

        switch prefs.idleBehavior {
        case .alwaysAnimate:
            metalView.isPaused = !isVisible
        case .freeze:
            // Paused, but the last frame stays on screen. Draw one final frame
            // first so it freezes on something current rather than on whatever
            // happened to be mid-turbulence.
            if isIdle, isVisible { metalView.draw() }
            metalView.isPaused = isIdle || !isVisible
        case .fadeOut:
            metalView.isPaused = isIdle || !isVisible
            if isVisible { window.alphaValue = isIdle ? 0 : 1 }
        }
    }

    /// Re-read the settings that live on the view rather than in the uniforms.
    func applySettings() {
        metalView?.preferredFramesPerSecond = prefs.frameRate
        borderView?.isHidden = renderer != nil && prefs.debugMode == 0
    }

    /// The only entry point. `nil` hides the ring.
    func update(with state: FocusState?) {
        guard let state, shouldShow(state) else {
            hide()
            return
        }

        // Remember where the window is even while suppressed, so the ring can
        // reappear in the right place the moment the drag ends.
        guard !isSuppressedByMotion else {
            lastState = state
            return
        }

        let margin = prefs.margin
        let frame = Geometry.overlayFrame(for: state.frame,
                                          margin: margin,
                                          screenUnion: OverlayController.screenUnion())
        guard frame.width > 0, frame.height > 0 else {
            hide()
            return
        }

        window.setFrame(frame, display: false)
        // After the frame is set, so the window knows which screen it is on.
        updateBackingScale()
        // Both rects are AppKit screen coords and the view is unflipped, so the
        // window rect maps into view space by a plain origin shift.
        let windowRectInView = state.frame.offsetBy(dx: -frame.origin.x,
                                                    dy: -frame.origin.y)

        let (inner, outer) = Geometry.clampedBand(inner: prefs.bandWidth.points.inner,
                                                  outer: prefs.bandWidth.points.outer,
                                                  window: state.frame)
        if let renderer {
            renderer.debugMode = prefs.debugMode
            renderer.flowSpeed = prefs.motionSpeed.flowSpeed
            renderer.noiseScale = prefs.turbulence.noiseScale
            renderer.animator.idleIntensity = Float(prefs.idleIntensity)
            renderer.animator.flareDuration = Float(prefs.flareDuration)
            renderer.windowRect = windowRectInView
            renderer.bandInnerPoints = inner
            renderer.bandOuterPoints = outer
            // Native full-screen windows have square corners.
            renderer.cornerRadiusPoints = state.isFullScreen ? 0 : 11
        }
        borderView?.windowRect = windowRectInView
        borderView?.isHidden = renderer != nil && prefs.debugMode == 0

        if !isVisible {
            window.orderFront(nil)
            window.alphaValue = 1
            metalView?.isPaused = displaysAreAsleep
            // Draw one frame synchronously rather than waiting up to a frame
            // interval for the display link, so the ring is there the instant
            // the window appears.
            if !displaysAreAsleep { metalView?.draw() }
            isVisible = true
            Log.write("overlay shown for \(state.bundleID ?? "pid \(state.pid)")")
            if prefs.debugMode > 0 { logWindowDiagnostics() }
        }
        flareIfWindowChanged(to: state)
        lastState = state
    }

    func hide() {
        guard isVisible else { return }
        Log.write("overlay hidden")
        // Pause before ordering out: a hidden view that keeps its draw loop
        // running is pure battery cost for pixels nobody sees.
        metalView?.isPaused = true
        window.orderOut(nil)
        isVisible = false
        lastState = nil
    }

    /// Everything needed to tell "the window is not on screen" from "the window
    /// is on screen and its contents are not reaching it". Kept because that
    /// distinction took a long time to establish once; enabled with
    /// `defaults write com.vivasonico.focusring debugMode -int 1`.
    private func logWindowDiagnostics() {
        Log.write("  window visible=\(window.isVisible) frame=\(window.frame) "
                  + "level=\(window.level.rawValue) alpha=\(window.alphaValue) "
                  + "occluded=\(!window.occlusionState.contains(.visible)) "
                  + "screen=\(window.screen.map { "\($0.frame)" } ?? "none")")
        Log.write("  view frame=\(metalView?.frame ?? .zero) "
                  + "layerScale=\(metalView?.layer?.contentsScale ?? -1) "
                  + "layerOpaque=\(metalView?.layer?.isOpaque.description ?? "?") "
                  + "windowOpaque=\(window.isOpaque)")
        logWindowStack()
    }

    /// Dump every on-screen window that overlaps ours, with its window level.
    /// If something sits at or above the overlay's level it will cover the ring,
    /// and no amount of shader work will make it appear.
    private func logWindowStack() {
        let ours = window.frame
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        // Our own window needs no Screen Recording permission to appear here.
        // If it is missing from the on-screen list, the window server does not
        // consider it on screen at all and nothing we render can ever show.
        let ourNumber = window.windowNumber
        let found = list.contains { ($0[kCGWindowNumber as String] as? Int) == ourNumber }
        Log.write("  window stack: \(list.count) on-screen windows; "
                  + "ours (number=\(ourNumber), level=\(window.level.rawValue)) "
                  + (found ? "IS present" : "is NOT present"))
        for entry in list.prefix(40) {
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let number = entry[kCGWindowNumber as String] as? Int else { continue }
            // CGWindow bounds are top-left origin; only a rough overlap test is
            // needed to spot a window sitting on top of ours.
            guard rect.width > 100, rect.height > 100 else { continue }
            let marker = number == window.windowNumber ? " <== OURS" : ""
            Log.write("    layer=\(layer) \(owner) \(Int(rect.width))x\(Int(rect.height))"
                      + " at \(Int(rect.origin.x)),\(Int(rect.origin.y))\(marker)")
        }
        _ = ours
    }

    // MARK: - Policy

    private func shouldShow(_ state: FocusState) -> Bool {
        guard prefs.enabled else { return false }

        // Never ring ourselves (§10) — the prefs window taking focus should not
        // produce a ring around it.
        if state.pid == ProcessInfo.processInfo.processIdentifier { return false }

        if let bundleID = state.bundleID, prefs.exclusions.contains(bundleID) {
            return false
        }
        if state.isFullScreen && prefs.hideInFullScreen { return false }
        if !Geometry.isSensible(state.frame) { return false }

        return true
    }

    /// Keep the Metal layer's `contentsScale` in step with whichever display the
    /// overlay is currently on.
    ///
    /// This is not just the mixed-scale requirement from §10 — it is load
    /// bearing. A `CAMetalLayer` whose `contentsScale` is 0 renders correctly
    /// and composites to nothing at all: the draw loop runs, the drawable is
    /// presented, no error is reported anywhere, and the screen stays empty.
    /// A borderless window that has not yet been placed on a screen can leave
    /// the layer at 0, so it is set explicitly on every placement.
    private func updateBackingScale() {
        guard let metalView, let layer = metalView.layer else { return }
        let scale = max(window.screen?.backingScaleFactor ?? window.backingScaleFactor, 1)
        guard layer.contentsScale != scale else { return }
        layer.contentsScale = scale
        Log.write("backing scale -> \(scale)")
    }

    /// Union of every attached screen, used to clip the overlay so it can never
    /// be placed off-desktop. Read fresh each time: a display can appear or
    /// disappear between two focus changes.
    static func screenUnion() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// Re-place the overlay after a screen change without waiting for the next
    /// focus event.
    func refresh() {
        update(with: lastState)
    }
}
