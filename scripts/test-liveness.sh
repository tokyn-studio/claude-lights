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

# Sleeper binary under a .../claude/versions/ path for the pid-liveness tests
# (freshly built — copied system binaries can wedge in dyld and hang).
mkdir -p "$WORK/claude/versions"
printf 'import Foundation\nThread.sleep(forTimeInterval: 600)\n' > "$WORK/waiter.swift"
xcrun swiftc -o "$WORK/claude/versions/waiter" "$WORK/waiter.swift"

"$WORK/livenesstest" "$WORK/claude/versions/waiter"
