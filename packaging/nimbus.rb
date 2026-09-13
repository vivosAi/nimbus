# Homebrew cask. Goes in a tap repository named `homebrew-tap`, at
# `Casks/nimbus.rb`, so people can install with:
#
#   brew install --cask vivosAi/tap/nimbus
#
# Since 1 September 2026 Homebrew refuses casks that fail Gatekeeper, so the
# .dmg this points at must be signed with a Developer ID and notarised. Fill in
# version, sha256 (printed by `make dmg`) and the release URL.
cask "nimbus" do
  version "0.1.0"
  sha256 "779348e2d56f7b29d8cf753115e1b83ff2d810f11a212154b30ce63c259d7fcc"

  url "https://github.com/vivosAi/nimbus/releases/download/v#{version}/Nimbus.dmg"
  name "Nimbus"
  desc "Draws an animated ring of light around the focused window"
  homepage "https://github.com/vivosAi/nimbus"

  depends_on macos: ">= :ventura"

  app "Nimbus.app"

  uninstall quit: "io.github.vivosai.nimbus"

  # The Accessibility grant is keyed to the bundle identifier, so macOS keeps it
  # after an uninstall. Clear it too, or a reinstall inherits a stale entry.
  zap trash: [
    "~/Library/Preferences/io.github.vivosai.nimbus.plist",
  ]
end
