# Nimbus — build, bundle, sign.
#
# The Accessibility grant is keyed to BUNDLE_ID plus the code signature. Signing
# every build with the same stable identity is what lets the permission survive
# rebuilds; with ad-hoc signing you would re-tick the checkbox after every build.
# When this ships publicly, swap SIGN_IDENTITY for a Developer ID and add a
# notarize target — nothing else here changes.

BUNDLE_ID     := io.github.vivosai.nimbus

# A secure timestamp is required for notarisation and impossible for a
# self-signed local identity, so it is off by default and switched on by `dist`.
TIMESTAMP     ?= --timestamp=none
APP           := build/Nimbus.app
# macOS keys the Accessibility grant to the code signature, so an unstable
# identity means re-granting the permission after every build.
#
# Prefer a Developer ID when the machine has one: then local builds carry the
# same signature as released ones, and the permission survives both rebuilds
# and updates. Fall back to a self-signed local identity otherwise — see the
# README for creating one. A self-signed identity is not a distribution
# credential; no other Mac trusts it.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := FocusRing Dev
endif
ARCHS         := --arch arm64 --arch x86_64

.PHONY: all build release test bundle dev run dev-run stop clean reset-permission cert-info icon dmg dist

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
	codesign --force --options runtime $(TIMESTAMP) \
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
	codesign --force $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" \
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

# Your Developer ID, e.g. "Developer ID Application: Acme Ltd (AB12CD34EF)".
# Find it with: security find-identity -v -p codesigning
DEV_ID         ?=

## The whole distribution flow, in one command:
##
##   make dist DEV_ID="Developer ID Application: Acme Ltd (AB12CD34EF)"
##
## Apple is notarised rather than the app alone, and stapled, so the download
## opens even on a Mac with no network connection.
dist:
	@test -n "$(DEV_ID)" || { echo "ERROR: set DEV_ID=\"Developer ID Application: NAME (TEAMID)\""; \
		 echo "       Find it with: security find-identity -v -p codesigning"; exit 1; }
	@xcrun notarytool history --keychain-profile $(NOTARY_PROFILE) >/dev/null 2>&1 || \
		{ echo "ERROR: no notarisation credentials stored under profile '$(NOTARY_PROFILE)'."; \
		  echo "       Run: xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"; \
		  echo "              --apple-id YOUR@EMAIL --team-id TEAMID --password APP-SPECIFIC-PASSWORD"; \
		  exit 1; }
	$(MAKE) bundle SIGN_IDENTITY="$(DEV_ID)" TIMESTAMP="--timestamp"
	$(MAKE) dmg
	codesign --force --timestamp --sign "$(DEV_ID)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)
	@echo
	@echo "Ready to upload: $(DMG)"
	@echo "sha256 for the Homebrew cask:"
	@shasum -a 256 $(DMG) | sed 's/^/  /'

## A drag-to-Applications disk image, built from whatever is in $(APP).
dmg:
	@test -d $(APP) || { echo "No $(APP). Run 'make bundle' first."; exit 1; }
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Nimbus -srcfolder build/dmg -ov -format UDZO $(DMG)

cert-info:
	@security find-identity -v -p codesigning

clean:
	rm -rf .build build/Nimbus.app
