#!/usr/bin/env bash
#
# Headless logic tests for the donation prompt: auto-show rule thresholds,
# the two-show cap, opt-outs, and DonationStateStore persistence.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -o "$WORK/donationtest" \
  "$ROOT/ClaudeLights/DonationPrompt.swift" \
  "$ROOT/tests/donation/main.swift"

"$WORK/donationtest"
