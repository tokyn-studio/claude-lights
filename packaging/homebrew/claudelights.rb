# Homebrew cask for ClaudeLights.
#
# Lives in the tap repository (github.com/vanta-studio/homebrew-tap) at
# Casks/claudelights.rb; this copy is the source of truth. scripts/release.sh
# prints a filled-in stanza (version + sha256) after every notarized build —
# paste that into the tap and push.
#
# Install:  brew install --cask vanta-studio/tap/claudelights

cask "claudelights" do
  version "1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/vanta-studio/claude-lights/releases/download/v#{version}/ClaudeLights.dmg"
  name "ClaudeLights"
  desc "Menu bar traffic light for Claude Code sessions"
  homepage "https://github.com/vanta-studio/claude-lights"

  auto_updates true # Sparkle
  depends_on macos: ">= :ventura"

  app "ClaudeLights.app"

  zap trash: [
    "~/.claude/claudelights-status.json",
    "~/Library/Application Support/ClaudeLights",
    "~/Library/Caches/studio.vanta.claudelights",
    "~/Library/Preferences/studio.vanta.claudelights.plist",
  ]

  caveats <<~EOS
    Open ClaudeLights once and click "Install Hooks" to connect it to
    Claude Code (it adds hook entries to ~/.claude/settings.json; a backup
    is kept). Restart any running Claude Code sessions afterwards.

    Before uninstalling for good, click "Uninstall…" under Settings →
    Claude Code Hooks to remove those entries. If you forget, the leftover
    hooks are harmless no-ops (each entry checks that the helper binary
    still exists), but they stay in settings.json until removed manually.
  EOS
end
