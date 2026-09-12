# Nimbus — build, bundle, sign.
#
# The Accessibility grant is keyed to BUNDLE_ID plus the code signature. Signing
# every build with the same stable identity is what lets the permission survive
# rebuilds; with ad-hoc signing you would re-tick the checkbox after every build.
# When this ships publicly, swap SIGN_IDENTITY for a Developer ID and add a
# notarize target — nothing else here changes.

BUNDLE_ID     := io.github.vivosai.nimbus
APP           := build/Nimbus.app
# A self-signed local identity, used only so the Accessibility grant survives
# rebuilds — macOS keys that permission to the code signature, and ad-hoc
# signing changes it every build. Not a release credential: no other Mac trusts
# it. For distribution, override this with a Developer ID and notarise.
SIGN_IDENTITY ?= FocusRing Dev
ARCHS         := --arch arm64 --arch x86_64

.PHONY: all build release test bundle dev run dev-run stop clean reset-permission cert-info icon dmg notarize

all: bundle

## Debug build of the executable only.
build:
	swift build --product Nimbus

## Universal release binary: this machine is Intel, the other Mac is Apple Silicon.
release:
	swift build -c release $(ARCHS) --product Nimbus

test:
	swift test

## Assemble a real .app. Required for TCC to key permission to the bundle ID.
bundle: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	cp .build/apple/Products/Release/Nimbus $(APP)/Contents/MacOS/Nimbus
	@# Shaders are compiled at runtime from source (no Xcode Metal toolchain
	@# needed), so the .metal file ships as a plain resource.
	@if [ -f Sources/Nimbus/Render/Shaders.metal ]; then \
		cp Sources/Nimbus/Render/Shaders.metal $(APP)/Contents/Resources/; \
	fi
	@# --timestamp=none: no Apple timestamp server for a local identity.
	@# touch: keeps the bundle and its payload mtimes consistent, which
	@# codesign otherwise rejects as clock skew.
	touch $(APP)
	codesign --force --options runtime --timestamp=none \
		--sign "$(SIGN_IDENTITY)" \
		--entitlements Resources/Nimbus.entitlements \
		$(APP)
	@codesign --verify --verbose=2 $(APP) 2>&1 | sed 's/^/  /'
	@# Guard: codesign can silently fall back to an ad-hoc signature, which
	@# produces a cdhash-based designated requirement and quietly invalidates
	@# the Accessibility grant on every build. Fail loudly instead.
	@codesign -dvvv $(APP) 2>&1 | grep -q "Authority=$(SIGN_IDENTITY)" || \
		{ echo "ERROR: $(APP) is not signed with '$(SIGN_IDENTITY)'."; \
		  echo "       The Accessibility permission will be lost. Check 'make cert-info'."; \
		  exit 1; }
	@echo "Built $(APP) (universal: $$(lipo -archs $(APP)/Contents/MacOS/Nimbus))"

## Fast iteration: debug build, this architecture only, bundled and signed with
## the same identity so it reuses the existing Accessibility grant. Seconds
## rather than the minutes a universal release build takes.
dev: stop build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	cp .build/debug/Nimbus $(APP)/Contents/MacOS/Nimbus
	@if [ -f Sources/Nimbus/Render/Shaders.metal ]; then \
		cp Sources/Nimbus/Render/Shaders.metal $(APP)/Contents/Resources/; \
	fi
	touch $(APP)
	codesign --force --timestamp=none --sign "$(SIGN_IDENTITY)" \
		--entitlements Resources/Nimbus.entitlements $(APP)

dev-run: stop dev
	open $(APP)

## Launch the bundled app. Quit any previous copy first so the menu bar has one icon.
run: bundle stop
	open $(APP)

stop:
	@pkill -x Nimbus || true

## Only needed if the signature or bundle ID changes. With a stable identity the
## grant persists across rebuilds, so this should be rare.
reset-permission: stop
	tccutil reset Accessibility $(BUNDLE_ID)
	@echo "Accessibility reset. Re-tick Nimbus in System Settings > Privacy & Security > Accessibility."

## Regenerate the icon from Tools/make-icon.swift. Committed as a .icns so a
## normal build needs no extra tools, but reproducible from source.
icon:
	swift Tools/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# ---------------------------------------------------------------------------
# Distribution. Needs a Developer ID from an Apple Developer account:
#
#   make bundle SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
#   make notarize NOTARY_PROFILE=nimbus
#   make dmg
#
# Store notarisation credentials once, beforehand:
#   xcrun notarytool store-credentials nimbus --apple-id ... --team-id ... --password ...
# ---------------------------------------------------------------------------

NOTARY_PROFILE ?= nimbus
DMG            := build/Nimbus.dmg

## Submit to Apple and staple the ticket into the app. Stapling matters: it lets
## the app open on a Mac with no network connection.
notarize:
	@test -d $(APP) || { echo "No $(APP). Run 'make bundle' first."; exit 1; }
	@codesign -dvvv $(APP) 2>&1 | grep -q "Developer ID Application" || \
		{ echo "ERROR: $(APP) is not signed with a Developer ID."; \
		  echo "       Notarisation will be rejected. Rebuild with:"; \
		  echo "       make bundle SIGN_IDENTITY=\"Developer ID Application: NAME (TEAMID)\""; \
		  exit 1; }
	ditto -c -k --keepParent $(APP) build/Nimbus-notarize.zip
	xcrun notarytool submit build/Nimbus-notarize.zip \
		--keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP)
	xcrun stapler validate $(APP)

## A drag-to-Applications disk image.
dmg: 
	@test -d $(APP) || { echo "No $(APP). Run 'make bundle' first."; exit 1; }
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Nimbus -srcfolder build/dmg -ov -format UDZO $(DMG)
	@shasum -a 256 $(DMG)

cert-info:
	@security find-identity -v -p codesigning

clean:
	rm -rf .build build/Nimbus.app
