#!/usr/bin/env bash
#
# Build a runnable ClaudeLights.app WITHOUT full Xcode, using swiftc + the macOS
# SDK from the Command Line Tools. Produces build/ClaudeLights.app, ad-hoc
# signed so it launches locally.
#
# This is for quick local testing only. The real, distributable build is made
# with Xcode (see scripts/release.sh and the README). Some features that need a
# proper signed bundle (login item, notifications) may be limited here.
#
# Usage: scripts/dev-build.sh [--run]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/ClaudeLights.app"
SDK="$(xcrun --show-sdk-path)"

echo "Building $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Compile every Swift source in the app folder.
# AppKit and SwiftUI are auto-linked from their imports.
swiftc -O -o "$APP/Contents/MacOS/ClaudeLights" \
  -sdk "$SDK" \
  "$ROOT"/ClaudeLights/*.swift

# Compile the bundled hook helper (replaces the jq-based shell hooks).
mkdir -p "$APP/Contents/Helpers"
swiftc -O -o "$APP/Contents/Helpers/claudelights-hook" \
  -sdk "$SDK" \
  "$ROOT"/ClaudeLightsHook/*.swift

# Concrete Info.plist (the source Info.plist uses Xcode build variables).
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>ClaudeLights</string>
	<key>CFBundleIdentifier</key><string>studio.vanta.claudelights</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>ClaudeLights</string>
	<key>CFBundleDisplayName</key><string>ClaudeLights</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS lets it run locally.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built and signed."

if [ "${1:-}" = "--run" ]; then
  # Restart any running instance.
  pkill -f "build/ClaudeLights.app/Contents/MacOS/ClaudeLights" 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "Launched. Look for the traffic-light icon in the menu bar."
fi
