# FocusRing — Implementation Spec

A macOS menu-bar utility that draws an animated, colored ring of light around the
window that currently has keyboard focus.

**Target reader:** a coding agent (Claude Code) with a terminal on the user's Mac.
Follow the milestones in order. Each milestone should build, run, and be verified
by hand before moving on.

---

## 1. Problem

The user cannot reliably tell which window has keyboard focus. macOS signals it
only with a slightly darker title bar, which is invisible in practice on a large
or multi-monitor setup. The consequence is typing or pressing Enter into the wrong
window, which has real cost (closing the wrong thing, sending text to the wrong place).

The fix is an unmissable, continuously animated marker around the focused window.

## 2. Design goals

1. **Impossible to miss.** Peripheral vision should catch it without looking.
2. **Motion, always.** A static border becomes invisible within days. The ring must
   always have low-amplitude movement so the eye keeps registering it.
3. **Never habituating.** The color scheme rotates on a timer so the user never
   settles into one look. (See §8.)
4. **Never in the way.** Fully click-through, never takes focus, never covers the
   window's content. The ring is a band around the edge; the interior is fully
   transparent.
5. **Cheap.** Should be unnoticeable in CPU and battery terms.

## 3. Non-goals

- No screen recording, no screenshotting, no reading window contents.
- No window management (moving, tiling, resizing).
- No network access of any kind.
- Not a general theming tool.

## 4. Platform and technology decision

| Choice | Decision | Why |
| --- | --- | --- |
| OS | macOS 13 Ventura or later | `SMAppService` for login items, modern AX behavior |
| Language | **Swift** | See note below |
| Rendering | **Metal**, via `MTKView` in a transparent `NSWindow` | Cheapest way to run a per-pixel animated shader |
| Focus tracking | Accessibility API (`AXUIElement`, `AXObserver`) + `NSWorkspace` | Only supported way to get focused-window geometry without screen recording permission |
| Build | Swift Package Manager + a bundling script | Headless-friendly; no Xcode GUI needed |

**Note on language.** The user originally asked about C or Rust for efficiency.
That argument does not apply here. The host code runs a handful of times per second,
only on window-change events; there is no hot loop. All real work happens in a Metal
fragment shader, which is identical regardless of the calling language. Rust would
mean hand-writing `objc2` FFI glue for the Accessibility and AppKit APIs — significant
unsafe boilerplate for zero measurable gain. Swift is the right tool. Do not
substitute another language.

## 5. Architecture

```
FocusRing/
├── Package.swift
├── Makefile                      # build + assemble .app bundle + sign
├── Sources/FocusRing/
│   ├── main.swift                # NSApplication bootstrap, accessory policy
│   ├── AppDelegate.swift         # wires everything together
│   ├── Focus/
│   │   ├── AXPermission.swift    # trust check + prompt + polling until granted
│   │   ├── FocusTracker.swift    # AX observers, emits FocusState
│   │   └── Geometry.swift        # AX ↔ AppKit coordinate conversion
│   ├── Overlay/
│   │   ├── OverlayWindow.swift   # borderless click-through NSWindow
│   │   └── OverlayController.swift # positions overlay, drives show/hide
│   ├── Render/
│   │   ├── RingRenderer.swift    # MTKViewDelegate, uniforms, pipeline
│   │   ├── Uniforms.swift        # shared struct, must match Metal layout
│   │   └── Shaders.metal
│   ├── Style/
│   │   ├── Palette.swift         # palette list + rotation timer
│   │   └── Animator.swift        # flare → settle intensity curve
│   └── UI/
│       ├── StatusItem.swift      # menu bar icon and menu
│       └── Preferences.swift     # UserDefaults wrapper
└── Resources/
    └── (default.metallib is generated at build time)
```

Data flow, one direction only:

```
FocusTracker ──FocusState──▶ OverlayController ──frame──▶ OverlayWindow
                    │                  │
                    └──focusChanged───▶ Animator ──intensity──▶ RingRenderer
                                       Palette   ──colors────▶ RingRenderer
```

`FocusState` is:

```swift
struct FocusState: Equatable {
    let pid: pid_t
    let bundleID: String?
    let windowID: CGWindowID?     // best-effort, may be nil
    let frame: CGRect             // already converted to AppKit screen coords
    let isFullScreen: Bool
}
```

---

## 6. Focus tracking (`Focus/`)

### 6.1 Permission

The app is useless without Accessibility permission.

```swift
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
```

- If not trusted, show a small window explaining what is needed and a button that
  opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Poll `AXIsProcessTrusted()` every 1s in the background and start up automatically
  once it flips to true. Do not require an app restart.
- **Important gotcha for the dev loop:** the permission grant is tied to the app's
  code signature and path. Every rebuild with an ad-hoc signature invalidates it.
  Add `make reset-permission` running
  `tccutil reset Accessibility com.<user>.focusring`, and document that the checkbox
  must be re-ticked after rebuilds. Signing with a stable self-signed certificate
  reduces this pain; note it in the README but don't block on it.

### 6.2 Getting the focused window

```swift
guard let app = NSWorkspace.shared.frontmostApplication else { return }
let axApp = AXUIElementCreateApplication(app.processIdentifier)

var winRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
      CFGetTypeID(winRef!) == AXUIElementGetTypeID() else { return }
let axWindow = winRef as! AXUIElement
```

Read geometry with `kAXPositionAttribute` (unpacks to `CGPoint` via
`AXValueGetValue(_, .cgPoint, _)`) and `kAXSizeAttribute` (`.cgSize`).

Also read `kAXFullScreenAttribute` (may be absent; treat absence as false) and
`kAXSubroleAttribute` — ignore anything whose subrole is not
`kAXStandardWindowSubrole` unless it has a sane non-zero size. Sheets and popovers
should not steal the ring from their parent window; if the focused element is a
sheet (`AXSheet`), walk up via `kAXParentAttribute` to the owning window, or simply
keep the ring on the parent.

### 6.3 Events to subscribe to

Create one `AXObserver` per observed process:

```swift
AXObserverCreate(pid, callback, &observer)
CFRunLoopAddSource(CFRunLoopGetCurrent(),
                   AXObserverGetRunLoopSource(observer), .defaultMode)
```

Register on the **application element**:
- `kAXFocusedWindowChangedNotification`
- `kAXApplicationActivatedNotification`
- `kAXApplicationHiddenNotification`, `kAXApplicationShownNotification`
- `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`

Register on the **currently focused window element** (re-register on every focus change,
and remove the old registration to avoid leaking observers):
- `kAXWindowMovedNotification`
- `kAXWindowResizedNotification`
- `kAXUIElementDestroyedNotification`

Separately, on `NSWorkspace.shared.notificationCenter`:
- `didActivateApplicationNotification` → tear down the old observer, build one for
  the new PID. This is the master trigger for app switches.
- `didTerminateApplicationNotification` → clean up.

Also observe `NSApplication.didChangeScreenParametersNotification` (monitor
plugged/unplugged) and `NSWorkspace.didWakeNotification` (recompute everything, and
advance the palette — see §8).

### 6.4 Coordinate conversion (`Geometry.swift`)

This is the single most common source of bugs in this kind of app. AX returns
**global coordinates with the origin at the top-left of the primary display, y
growing downward.** AppKit uses **bottom-left origin, y growing upward, relative to
the primary display.**

```swift
enum Geometry {
    /// The screen containing the menu bar. Always index 0.
    static var primaryHeight: CGFloat { NSScreen.screens[0].frame.height }

    static func axToScreen(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x,
               y: primaryHeight - r.origin.y - r.height,
               width: r.width, height: r.height)
    }
}
```

Recompute `primaryHeight` on `didChangeScreenParametersNotification`; never cache it
across that event. Test explicitly with a secondary monitor positioned **above** and
**to the left** of the primary — both produce negative coordinates and are where
naive implementations break.

### 6.5 Tracking during drags and resizes

AX move/resize notifications are coalesced and lag badly during a live drag, so the
ring visibly trails the window. Handle it like this:

- On the first `kAXWindowMoved`/`kAXWindowResized` notification, enter **motion mode**.
- In motion mode, poll position and size at display refresh rate using a
  `CVDisplayLink` or a `Timer` at 60 Hz.
- Exit motion mode 250 ms after the last observed change.
- Do the AX reads on a background `DispatchQueue`, and never block the main thread on
  them. A hung app can make an AX call take seconds; use
  `AXUIElementSetMessagingTimeout(axApp, 0.25)` on every app element you create.
- If a poll times out or fails twice in a row, hide the overlay rather than leaving
  it stranded in the wrong place.

An acceptable v1 fallback, if the polling proves janky: fade the ring to 20% opacity
during motion mode and restore on exit. Ship whichever looks better.

---

## 7. The overlay window (`Overlay/`)

One overlay window, reused (never recreated per focus change — recreating causes
flicker).

```swift
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

Configuration:

```swift
window.styleMask          = [.borderless]
window.isOpaque           = false
window.backgroundColor    = .clear
window.hasShadow          = false
window.ignoresMouseEvents = true            // critical — must never eat clicks
window.level              = .floating       // NSWindow.Level(rawValue: kCGFloatingWindowLevel)
window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                             .fullScreenAuxiliary, .ignoresCycle]
window.isReleasedWhenClosed = false
window.animationBehavior  = .none           // no fade-in on orderFront
window.displaysWhenScreenProfileChanges = true
```

`NSApp.setActivationPolicy(.accessory)` in `main.swift` so the app has no Dock icon
and never becomes active.

**Frame:** the target window's frame, outset by `margin` (default 24 pt) on all
sides, then clipped so it never extends past the union of all screen frames. The
ring band is drawn inside this outset area, straddling the window edge:
roughly 6 pt inside the window edge and 18 pt outside it, so it reads as a glow
hugging the window without covering content.

**Content view:** an `MTKView` filling the window.

```swift
mtkView.layer?.isOpaque = false
(mtkView.layer as? CAMetalLayer)?.isOpaque = false
mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.framebufferOnly = true
mtkView.enableSetNeedsDisplay = false
mtkView.isPaused = false
mtkView.preferredFramesPerSecond = 30       // configurable, see §11
```

Hide the overlay (`orderOut`) when: no focused window, focused window is minimized
or hidden, the focused app is on the exclusion list, or the focused app is the
FocusRing prefs window itself.

---

## 8. Rendering (`Render/`)

### 8.1 Geometry

Draw a single full-viewport triangle strip (4 vertices) covering the overlay. The
fragment shader masks everything outside the band to alpha 0. Interior pixels cost
one SDF evaluation and an early return — negligible.

*Optional later optimization, only if profiling demands it:* replace the full quad
with a generated ring strip so interior fragments are never rasterized. Do not do
this in v1.

### 8.2 Uniforms

Must be byte-identical between Swift and Metal. Use `simd` types and
`MemoryLayout<Uniforms>.stride` for the buffer size.

```swift
struct Uniforms {
    var resolution:  SIMD2<Float>   // overlay size in pixels (backing scale applied)
    var windowRect:  SIMD4<Float>   // x, y, w, h of the *window* within the overlay, in px
    var cornerRadius: Float         // px
    var bandInner:   Float          // px inside the window edge
    var bandOuter:   Float          // px outside the window edge
    var time:        Float          // seconds since launch
    var intensity:   Float          // 0…1, from Animator
    var colorA:      SIMD3<Float>   // linear RGB
    var colorB:      SIMD3<Float>
    var colorGlow:   SIMD3<Float>
    var flowSpeed:   Float
    var noiseScale:  Float
}
```

Update `time` every frame; update the rest only when they change.

### 8.3 Fragment shader

Behavior, in order:

1. **Signed distance to a rounded rectangle.** `d < 0` inside the window,
   `d > 0` outside.
   ```metal
   float sdRoundBox(float2 p, float2 b, float r) {
       float2 q = abs(p) - b + r;
       return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
   }
   ```
2. **Band mask.** `band = smoothstep(bandOuter, 0.0, d) * smoothstep(-bandInner, 0.0, d)`
   — a soft-edged strip straddling `d == 0`. Feather both edges by 1.5 px minimum so
   there is no aliasing.
3. **Outer bloom.** `glow = exp(-max(d, 0.0) / glowFalloff)` where `glowFalloff`
   scales with `intensity`. This is what makes it visible peripherally.
4. **Perimeter coordinate.** Map the fragment to a position around the ring so
   brightness can travel along it. Use the angle from the window center,
   `u = atan2(p.y, p.x) / (2π) + 0.5`. Not arc-length-uniform on a rectangle, but
   visually fine and cheap. Do not spend time on an exact arc-length parameterization.
5. **Animated noise.** 3-octave fBm of a cheap 2D value noise, sampled at
   `(u * noiseScale, time * flowSpeed)`. This produces bright and dim patches that
   drift around the ring. Add a second, slower counter-rotating layer at half
   amplitude so the motion never looks like a simple loop.
6. **Color.** `mix(colorA, colorB, noise)`, plus `colorGlow * glow`, all multiplied
   by `intensity`.
7. **Output premultiplied alpha:** `return float4(rgb * a, a)` and configure the
   pipeline's blend state accordingly:
   ```swift
   attachment.isBlendingEnabled = true
   attachment.rgbBlendOperation = .add
   attachment.alphaBlendOperation = .add
   attachment.sourceRGBBlendFactor = .one          // premultiplied
   attachment.sourceAlphaBlendFactor = .one
   attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
   attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
   ```

**Motion safety constraint.** The noise must be low-frequency and smooth. No
component of the animation may produce full-band brightness oscillation faster than
~2 Hz, and there must be no hard on/off flashing at any point. This is both a
comfort and a photosensitivity requirement. Keep the flow speed slow enough that
the movement reads as drifting, not flickering.

### 8.4 Flare and settle (`Animator.swift`)

This is the core interaction. The eye detects change far better than steady state,
so a focus change gets a bright pulse that then relaxes into a calm, still-moving
baseline.

- On focus change to a different window: set `intensity = 1.0`.
- Decay toward `idleIntensity` (default **0.30**) with an ease-out curve over
  `flareDuration`, default **2.5 s**.
  ```
  intensity(t) = idle + (1.0 - idle) * exp(-3.0 * t / flareDuration)
  ```
- During the flare, also scale `bandOuter` by up to 1.6× and `flowSpeed` by 1.8×,
  interpolated by the same curve, so the ring visibly swells and then relaxes.
- At idle, the ring is still fully animated, just dimmer and narrower.
- Both `idleIntensity` and `flareDuration` are user preferences.

> **Assumption flagged for the user.** The request said "the ideal is if I bring it in
> 23 seconds," which I've read as **2–3 seconds** for the flare before it settles.
> `flareDuration = 2.5` implements that. If 23 seconds was literal, change the default
> — but note that a 23-second decay means the ring is near full brightness for most of
> a normal window-switching rhythm, which will be tiring. Try 2.5 s first.

### 8.5 Palette rotation (`Palette.swift`)

To prevent habituation, the color scheme changes on a timer.

- **Interval:** default **30 minutes**, user-configurable (10 min / 30 min / 1 h /
  never).
- **Selection:** random from the palette list, never the same as the current one, and
  never repeating any of the last 3.
- **Transition:** cross-fade `colorA`, `colorB`, `colorGlow` in linear RGB over 3 s.
  Never a hard cut.
- **Also rotate on:** wake from sleep, and on unlock. A new palette on returning to
  the machine is exactly when the novelty is most useful.
- **Persist** the current index and the timestamp of the last change in `UserDefaults`
  so a restart doesn't reset the cycle.
- Menu bar item gets a "Next color now" command.

Starting palette list — `colorA`, `colorB`, `colorGlow` as sRGB hex, converted to
linear RGB before upload:

| Name | A | B | Glow |
| --- | --- | --- | --- |
| Ember | `#FF3D00` | `#FFC400` | `#FF6D00` |
| Plasma | `#7C4DFF` | `#00E5FF` | `#536DFE` |
| Toxic | `#76FF03` | `#00E676` | `#B2FF59` |
| Magma | `#D50000` | `#FF6E40` | `#FF1744` |
| Ice | `#18FFFF` | `#82B1FF` | `#40C4FF` |
| Neon Rose | `#FF4081` | `#F50057` | `#FF80AB` |
| Solar | `#FFD600` | `#FFAB00` | `#FFEA00` |
| Aurora | `#00E676` | `#00B0FF` | `#1DE9B6` |
| Ultraviolet | `#E040FB` | `#651FFF` | `#AA00FF` |
| Copper | `#FF9100` | `#FFD180` | `#FF6D00` |

All are high-chroma and bright, because the ring must win against arbitrary window
content. Users can disable individual palettes in preferences.

---

## 9. Menu bar UI (`UI/`)

`NSStatusItem` with a template SF Symbol (`rays` or `circle.dashed`). Menu:

- **Enabled** (toggle, ⌥⌘R global hotkey optional — skip in v1)
- **Next color now**
- ―
- **Intensity** ▸ Subtle / Normal / Loud (maps `idleIntensity` to 0.18 / 0.30 / 0.50)
- **Band width** ▸ Thin / Normal / Thick
- **Frame rate** ▸ 30 / 60 (default 30)
- **Change color every** ▸ 10 min / 30 min / 1 hour / Never
- ―
- **Exclude frontmost app** (adds current bundle ID to the exclusion list)
- **Manage exclusions…**
- ―
- **Open at Login** (toggle, `SMAppService.mainApp.register()`)
- **Quit**

All settings in `UserDefaults` under suite `com.<user>.focusring`, with a
`Preferences` struct exposing typed accessors and defaults.

---

## 10. Edge cases — implement and verify each

| Case | Required behavior |
| --- | --- |
| Native full-screen app | `.fullScreenAuxiliary` should let the ring show. If it doesn't render correctly, hide the ring instead of showing it broken. Add a "hide in full screen" preference, default on. |
| Multiple displays, mixed scale factors | Ring renders at correct size and sharpness on each. Handle `NSWindow.backingScaleFactor` changes when the overlay moves between displays; update `mtkView.drawableSize`. |
| Secondary display above/left of primary | Negative coordinates handled correctly. |
| Mission Control / App Exposé invoked | Ring will look wrong. Hide the overlay while active — detect via the `com.apple.dock` process becoming frontmost, or accept the brief artifact in v1. |
| Window smaller than the band | Clamp band widths to `min(w, h) / 4`. |
| Zero-size or absurd frames | Reject frames with w or h < 40 pt or > 20000 pt; hide overlay. |
| App that misreports geometry (some Java, Electron, and game windows) | Exclusion list is the escape hatch. Don't try to fix per-app. |
| Screen sharing / recording in progress | No special handling; the ring will appear in recordings. Document it. |
| Display sleep | Pause the `MTKView` (`isPaused = true`) on `NSWorkspace.screensDidSleepNotification`. |
| No user input for 5 minutes | Pause rendering; resume on the next input or focus change. Use `CGEventSource.secondsSinceLastEventType`. |
| Focused app is FocusRing's own prefs | Hide the ring. |

---

## 11. Performance budget

Measure with Activity Monitor and Instruments before declaring done.

- Idle CPU (ring visible, animating, 30 fps, 1440×900 window): **< 2%** on Apple Silicon.
- CPU when no window focus change is happening and rendering is paused: **< 0.1%**.
- Memory: **< 60 MB** resident.
- No measurable impact on the frame rate of the app being ringed.

If the budget is exceeded, in order: drop to 30 fps, reduce fBm to 2 octaves, then
switch to the ring-strip geometry from §8.1.

---

## 12. Build and packaging

`Package.swift` declares an executable target. The Metal shader is compiled in the
Makefile, not by SPM:

```make
metallib:
	xcrun -sdk macosx metal -c Sources/FocusRing/Render/Shaders.metal -o build/Shaders.air
	xcrun -sdk macosx metallib build/Shaders.air -o build/default.metallib

bundle: metallib
	swift build -c release
	# assemble FocusRing.app/Contents/{MacOS,Resources}
	# copy Info.plist, binary, default.metallib
	codesign --force --deep --sign - --entitlements FocusRing.entitlements FocusRing.app
```

`Info.plist` must include `LSUIElement = true` and a `CFBundleIdentifier` that stays
stable across builds (the TCC permission is keyed to it).

Load the shader library with
`device.makeDefaultLibrary()`, falling back to
`device.makeLibrary(URL: Bundle.main.url(forResource: "default", withExtension: "metallib")!)`.

No sandbox — the Accessibility API is incompatible with App Sandbox for this use.
Not intended for the App Store.

---

## 13. Milestones

Build and verify each before starting the next.

**M0 — Skeleton.** SPM executable, accessory activation policy, status item with a
Quit menu, Accessibility permission check with prompt and auto-detect of the grant.
*Verify:* app runs with no Dock icon; toggling the checkbox in System Settings is
detected within 1 s.

**M1 — Focus tracking, no UI.** `FocusTracker` logging every focus change with PID,
bundle ID, and converted frame. *Verify:* log values match reality when switching
apps, switching windows within an app, moving a window, resizing it, and moving it to
a second display. Verify on a monitor placed above and to the left of the primary.

**M2 — Overlay, solid color.** Transparent click-through window tracking the focused
window with a plain 3 pt solid border. *Verify:* clicks pass through everywhere;
overlay never takes focus; it tracks correctly across all M1 scenarios; no flicker on
switch.

**M3 — Metal ring.** Replace the solid border with the SDF band, bloom, and animated
fBm from §8.3. Fixed color for now. *Verify:* correct alpha compositing (no gray box,
no dark halo), sharp on Retina, motion is smooth and slow.

**M4 — Flare and palettes.** `Animator` (§8.4) and `Palette` rotation (§8.5).
*Verify:* flare on switch settles in ~2.5 s; palette changes cross-fade at the
interval; a restart resumes the cycle rather than resetting it.

**M5 — Preferences and polish.** Full menu, exclusions, launch at login, idle
pausing, edge-case table from §10, performance budget from §11.

---

## 14. Acceptance checklist

- [ ] Can be used for an hour without noticing it except when switching windows.
- [ ] Never a single click swallowed by the overlay.
- [ ] Never steals keyboard focus.
- [ ] Correct on a two-monitor setup, including different scale factors.
- [ ] Survives sleep/wake, display disconnect/reconnect, and app crashes of the
      tracked app without leaving a stranded ring on screen.
- [ ] Meets the performance budget in §11.
- [ ] Uninstall = quit and delete the .app; nothing left behind but a UserDefaults
      plist.

---

## 15. Fallback path

If Metal transparency proves troublesome (a transparent `CAMetalLayer` compositing
incorrectly is the most likely blocker), there is a simpler route that gets 80% of
the effect: a `CALayer` hierarchy with a `CAShapeLayer` rounded-rect stroke, a
`CAGradientLayer` mask animated by a rotating `startPoint`/`endPoint`, and a
`shadowOpacity`-based bloom. No shader, no Metal setup, driven entirely by
`CABasicAnimation`. Less organic-looking motion, but it will never have a
compositing bug. Fall back to this rather than losing days to Metal alpha issues.
