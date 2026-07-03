#!/usr/bin/env bash
#
# Golden test: the compiled claudelights-hook helper must produce the same
# status file as the legacy hooks/update-status.sh for identical event
# sequences.
#
# Usage: scripts/test-hook-parity.sh <path-to-claudelights-hook>
#
# Each case pipes the same payloads through both implementations into separate
# temp status files, then diffs them after normalizing:
#   - ISO timestamps are replaced with "TS" (runs may straddle a second)
#   - active_seconds is compared separately with a ±1s tolerance
#   - fields only the helper writes (cwd, bundle_id, tmux_pane, wezterm_pane,
#     kitty_window_id, kitty_listen_on) are dropped before diffing

set -uo pipefail

HELPER="${1:?usage: test-hook-parity.sh <path-to-claudelights-hook>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY="$ROOT/hooks/update-status.sh"

if [ ! -x "$HELPER" ]; then
  echo "FAIL: helper not found or not executable: $HELPER" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "FAIL: jq required for the test itself" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

# Apply one event to both implementations.
#   apply <state> <payload-json>
apply() {
  local state="$1" payload="$2"
  printf '%s' "$payload" | CLAUDELIGHTS_STATUS_FILE="$A" "$LEGACY" "$state"
  printf '%s' "$payload" | CLAUDELIGHTS_STATUS_FILE="$B" "$HELPER" "$state"
}

# Normalize a status file for diffing (timestamps masked, helper-only fields
# and active_seconds removed — active_seconds is checked separately).
normalize() {
  local file="$1"
  if [ ! -f "$file" ]; then echo "<absent>"; return; fi
  jq -S 'walk(
      if type == "object" then del(.cwd, .bundle_id, .tmux_pane, .wezterm_pane,
                                   .kitty_window_id, .kitty_listen_on, .pid,
                                   .active_seconds)
      else . end
    )
    | walk(if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then "TS" else . end)' \
    "$file" 2>/dev/null || echo "<unparseable>"
}

# Compare active_seconds per session with ±1s tolerance.
active_seconds_match() {
  [ -f "$A" ] || return 0
  local sids sid av bv
  sids="$(jq -r 'keys[]' "$A" 2>/dev/null)" || return 0
  for sid in $sids; do
    av="$(jq -r --arg s "$sid" '(.[$s] | objects | .active_seconds) // 0' "$A")"
    bv="$(jq -r --arg s "$sid" '(.[$s] | objects | .active_seconds) // 0' "$B" 2>/dev/null || echo missing)"
    [ "$bv" = "missing" ] && return 1
    local diff=$(( ${av%.*} - ${bv%.*} ))
    [ "${diff#-}" -le 1 ] || return 1
  done
}

check() {
  local name="$1" na nb
  na="$(normalize "$A")"
  nb="$(normalize "$B")"
  if [ "$na" = "$nb" ] && active_seconds_match; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    diff <(printf '%s\n' "$na") <(printf '%s\n' "$nb") | sed 's/^/  /' || true
    if ! active_seconds_match; then
      echo "  active_seconds mismatch: A=$(jq -c 'map_values(.active_seconds)' "$A" 2>/dev/null)" \
           "B=$(jq -c 'map_values(.active_seconds)' "$B" 2>/dev/null)"
    fi
    FAILURES=$((FAILURES + 1))
  fi
}

new_case() {
  A="$WORK/$1-a.json"
  B="$WORK/$1-b.json"
}

P1='{"session_id":"s1","cwd":"/tmp/projects/frontend"}'
P2='{"session_id":"s2","cwd":"/tmp/projects/api"}'

# --- Case 1: new session starts working -------------------------------------
new_case c1
apply working "$P1"
check "new session (working)"

# --- Case 2: working -> done banks the active stretch -----------------------
new_case c2
apply working "$P1"
sleep 2
apply done "$P1"
check "working -> done (stretch banked)"

# --- Case 3: resume after needs_input restarts the clock, keeps accumulator -
new_case c3
apply working "$P1"
sleep 1
apply needs_input "$P1"
apply resume "$P1"
check "needs_input -> resume (clock restarted, stored as working)"

# --- Case 4: repeated working resets the accumulator ------------------------
new_case c4
apply working "$P1"
sleep 1
apply done "$P1"
apply working "$P1"
check "second working (accumulator reset)"

# --- Case 5: compacting keeps an active stretch running ---------------------
new_case c5
apply working "$P1"
apply compacting "$P1"
check "working -> compacting (started preserved)"

# --- Case 6: two sessions never clobber each other --------------------------
new_case c6
apply working "$P1"
apply working "$P2"
apply done "$P1"
check "two sessions independent"

# --- Case 7: remove deletes only that session -------------------------------
new_case c7
apply working "$P1"
apply working "$P2"
apply remove "$P1"
check "remove deletes one session"

# --- Case 8: remove on a missing file is a no-op ----------------------------
new_case c8
apply remove "$P1"
check "remove on missing file"

# --- Case 9: corrupt existing file is treated as empty ----------------------
new_case c9
echo 'not json {{{' > "$A"
echo 'not json {{{' > "$B"
apply working "$P1"
check "corrupt file treated as empty"

# --- Case 10: empty stdin writes nothing ------------------------------------
new_case c10
apply working ""
check "empty stdin (no write)"

# --- Case 11: payload without session_id writes nothing ---------------------
new_case c11
apply working '{"cwd":"/tmp/x"}'
check "missing session_id (no write)"

# --- Case 12: payload without cwd -> project null ---------------------------
new_case c12
apply working '{"session_id":"s3"}'
check "missing cwd (project null)"

# --- Case 13: foreign top-level values survive the merge --------------------
new_case c13
printf '{"version": 2, "note": "keep me"}' > "$A"
printf '{"version": 2, "note": "keep me"}' > "$B"
apply working "$P1"
apply done "$P1"
check "foreign top-level values preserved"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed."
  exit 1
fi
echo "All parity cases passed."
