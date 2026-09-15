# Homebrew cask. Goes in a tap repository named `homebrew-tap`, at
# `Casks/nimbus.rb`, so people can install with:
#
#   brew install --cask vivosAi/tap/nimbus
#
# Since 1 September 2026 Homebrew refuses casks that fail Gatekeeper, so the
# .dmg this points at must be signed with a Developer ID and notarized. Fill in
# version, sha256 (printed by `make dmg`) and the release URL.
cask "nimbus" do
  version "0.1.2"
  sha256 "7002cc1827fb550889fb2f3414875b0b902aca1f7e3bbcb4d9abb84c31da749e"

  url "https://github.com/vivosAi/nimbus/releases/download/v#{version}/Nimbus.dmg"
  name "Nimbus"
  desc "Draws an animated ring of light around the focused window"
  homepage "https://github.com/vivosAi/nimbus"

  depends_on macos: :ventura

  app "Nimbus.app"

  uninstall quit: "io.github.vivosai.nimbus"

  # The Accessibility grant is keyed to the bundle identifier, so macOS keeps it
  # after an uninstall. Clear it too, or a reinstall inherits a stale entry.
  zap trash: [
    "~/Library/Preferences/io.github.vivosai.nimbus.plist",
  ]
end
