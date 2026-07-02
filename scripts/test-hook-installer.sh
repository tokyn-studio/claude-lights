#!/usr/bin/env bash
#
# Headless fixture tests for HookInstaller (settings.json merge, backups,
# migration, self-heal). Compiles the installer together with the test driver
# in tests/installer and runs it against a freshly built helper binary.
#
# Usage: scripts/test-hook-installer.sh [path-to-claudelights-hook]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HELPER="${1:-}"
if [ -z "$HELPER" ]; then
  HELPER="$WORK/claudelights-hook"
  xcrun swiftc -O -o "$HELPER" "$ROOT"/ClaudeLightsHook/*.swift
fi

xcrun swiftc -o "$WORK/installertest" \
  "$ROOT/ClaudeLights/HookInstaller.swift" \
  "$ROOT/tests/installer/main.swift"

"$WORK/installertest" "$HELPER"
