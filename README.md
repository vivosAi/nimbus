# FocusRing

A macOS menu-bar utility that draws an animated ring of light around the window
that currently has keyboard focus, so you never type into the wrong window.

Implementation follows `focusring-spec.md`. Deviations from the spec are noted
at the bottom of this file.

## Requirements

- macOS 13 Ventura or later
- Xcode command line tools (Swift 5.9+)
- No Xcode Metal toolchain needed — the shader compiles at runtime

## Build

```sh
make test      # unit tests (coordinate math, palettes, flare curve)
make bundle    # universal (arm64 + x86_64) signed FocusRing.app in build/
make run       # build, quit any running copy, launch
```

## Code signing and the Accessibility permission

macOS keys the Accessibility grant to the bundle ID **and** the code signature.
With ad-hoc signing (`--sign -`) the signature changes on every build, so the
permission is invalidated and you must re-tick the checkbox every single time.

This project therefore signs with a stable self-signed identity, `FocusRing Dev`,
which makes the grant survive rebuilds. It was created once with:

```sh
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -config build/cert/ext.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -out focusring.p12 \
  -name "FocusRing Dev" -passout pass:focusring
security import focusring.p12 -k ~/Library/Keychains/login.keychain-db \
  -P focusring -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db cert.pem
```

Check it is present with `make cert-info`. To set the project up on the other
Mac, either repeat those commands there or export the identity from Keychain
Access and import it on the second machine.

If the permission ever gets into a bad state:

```sh
make reset-permission
```

then re-tick FocusRing under System Settings → Privacy & Security → Accessibility.

**To ship this publicly**, set `SIGN_IDENTITY` to a Developer ID Application
certificate and add a notarization step. Nothing else in the build changes.

## What it can and cannot see

FocusRing asks for Accessibility permission only to read *which* window has
focus and *where it is*. It does not read window contents, does not record or
screenshot the screen, and makes no network connections of any kind.

Uninstalling is quitting it and deleting the `.app`. The only thing left behind
is a preferences plist in `~/Library/Preferences/com.vivasonico.focusring.plist`.

## Deviations from the spec

- **Two SPM targets instead of one.** `FocusRingKit` holds the pure logic
  (coordinate conversion, palettes, the flare curve, preferences) so it can be
  unit-tested; `FocusRing` is the AppKit/Metal shell. The spec's file layout is
  otherwise preserved.
- **Shaders compile at runtime** via `makeLibrary(source:)` rather than a
  build-time `.metallib`. The Xcode Metal toolchain is not installed on the dev
  machine, and runtime compilation removes the dependency entirely.
- **Idle behaviour is a preference, default "freeze".** The spec (§10) pauses
  rendering after 5 minutes of no input. Pausing an `MTKView` stops redrawing but
  leaves the last frame on screen, so the ring stays visible while costing no
  GPU — which matters because walking back to the machine and looking at which
  window has focus is the app's primary use case. The first input after an idle
  stretch, and wake from sleep, both fire a full flare.
