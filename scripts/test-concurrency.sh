#!/usr/bin/env bash
#
# Headless tests for ConcurrencyStats (parallel-session analytics).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -o "$WORK/conctest" \
  "$ROOT/ClaudeLights/ConcurrencyStats.swift" \
  "$ROOT/tests/concurrency/main.swift"

"$WORK/conctest"
