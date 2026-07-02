#!/usr/bin/env bash
#
# Headless logic tests for the focus-strategy chain (validation, binary
# resolution, subprocess timeouts, fall-through). The per-terminal happy
# paths (tmux, kitty, WezTerm, Terminal/iTerm AppleScript) need a manual
# pass on a machine with those terminals installed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -o "$WORK/focustest" \
  "$ROOT/ClaudeLights/Models.swift" \
  "$ROOT/ClaudeLights/FocusStrategies.swift" \
  "$ROOT/tests/focus/main.swift"

"$WORK/focustest"
