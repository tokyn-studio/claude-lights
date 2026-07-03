#!/usr/bin/env bash
#
# Headless tests for dead-session pruning (ps parsing + two-miss rule).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -o "$WORK/livenesstest" \
  "$ROOT/ClaudeLights/Models.swift" \
  "$ROOT/ClaudeLights/SessionStore.swift" \
  "$ROOT/ClaudeLights/FocusStrategies.swift" \
  "$ROOT/ClaudeLights/ProcessLiveness.swift" \
  "$ROOT/tests/liveness/main.swift"

"$WORK/livenesstest"
