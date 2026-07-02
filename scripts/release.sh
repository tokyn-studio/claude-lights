#!/usr/bin/env bash
#
# Build a signed, notarized ClaudeLights.dmg for distribution outside the App
# Store. Uses only Apple tooling (xcodebuild, hdiutil, notarytool) — no external
# dependencies.
#
# REQUIREMENTS (one-time):
#   1. Full Xcode installed and selected:
#        sudo xcode-select -s /Applications/Xcode.app
#   2. An Apple Developer Program membership and a "Developer ID Application"
#      certificate in your login keychain.
#   3. Notarization credentials stored as a keychain profile named "claudelights":
#        xcrun notarytool store-credentials claudelights \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "app-specific-password"
#
# USAGE:
#   TEAM_ID=YOURTEAMID scripts/release.sh
#
# Environment variables:
#   TEAM_ID           (required) Your 10-character Apple Developer Team ID.
#   NOTARY_PROFILE    (optional) Keychain profile name. Default: claudelights.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claudelights}"

SCHEME="ClaudeLights"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/ClaudeLights.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/ClaudeLights.app"
DMG="$ROOT/build/ClaudeLights.dmg"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: full Xcode is required (xcodebuild not available)." >&2
  echo "Run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving"
xcodebuild \
  -project ClaudeLights.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  archive

echo "==> Exporting (Developer ID)"
# Generate export options with the caller's team id.
EXPORT_OPTS="$OUT/exportOptions.plist"
cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$EXPORT"

echo "==> Building styled DMG"
# Produces the "drag to Applications" window with background + positioned icons.
"$ROOT/scripts/make-dmg.sh" "$APP" "$DMG"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo ""
echo "Done: $DMG"
echo "Verify with: spctl -a -vv -t open --context context:primary-signature \"$DMG\""

# Emit the Homebrew cask stanza for the tap (version from the built app).
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
CASK_OUT="$ROOT/build/claudelights.rb"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
    "$ROOT/packaging/homebrew/claudelights.rb" > "$CASK_OUT"
echo ""
echo "Homebrew cask written to: $CASK_OUT"
echo "  version: $VERSION"
echo "  sha256:  $SHA256"
echo "Copy it to the tap repo as Casks/claudelights.rb after uploading the DMG"
echo "and appcast.xml to the GitHub release (see scripts/sparkle-appcast.sh)."
