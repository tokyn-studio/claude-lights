#!/usr/bin/env bash
#
# Tests the helper's handling of the (undocumented) background_tasks payload
# field: store when present, preserve when absent/malformed, clear on empty,
# filter non-running tasks, sanitize long/multiline descriptions.
#
# Usage: scripts/test-hook-background.sh [path-to-claudelights-hook]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HELPER="${1:-}"
if [ -z "$HELPER" ]; then
  HELPER="$WORK/claudelights-hook"
  xcrun swiftc -O -o "$HELPER" "$ROOT"/ClaudeLightsHook/*.swift
fi
command -v jq >/dev/null || { echo "FAIL: jq required for the test itself" >&2; exit 1; }

FAILURES=0
FILE=""

new_case() { FILE="$WORK/$1.json"; }

apply() { # <state> <payload-json>
  printf '%s' "$2" | CLAUDELIGHTS_STATUS_FILE="$FILE" "$HELPER" "$1"
}

expect() { # <name> <jq-boolean-expression>
  if [ "$(jq -r "$2" "$FILE" 2>/dev/null)" = "true" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 -- $(jq -c '.' "$FILE" 2>/dev/null || echo '<unreadable>')"
    FAILURES=$((FAILURES + 1))
  fi
}

TASKS_SUBAGENT='{"id":"a1","type":"subagent","status":"running","description":"Sleep then reply done","agent_type":"Explore"}'
TASKS_SHELL_NO_DESC='{"id":"b1","type":"shell","status":"running","command":"sleep 3 && echo bg-done"}'

# --- Case 1: Stop payload with tasks stores display descriptions ------------
new_case c1
apply done "{\"session_id\":\"s1\",\"cwd\":\"/tmp/p\",\"background_tasks\":[$TASKS_SUBAGENT,$TASKS_SHELL_NO_DESC]}"
expect "stores descriptions (desc, then command fallback)" \
  '.s1.background_tasks == ["Sleep then reply done","sleep 3 && echo bg-done"]'

# --- Case 2: payload without the field preserves the previous value ---------
new_case c2
apply done "{\"session_id\":\"s1\",\"background_tasks\":[$TASKS_SUBAGENT]}"
apply needs_input '{"session_id":"s1"}'
expect "needs_input without field preserves list" \
  '.s1.state == "needs_input" and .s1.background_tasks == ["Sleep then reply done"]'

# --- Case 3: working without the field preserves too ------------------------
new_case c3
apply done "{\"session_id\":\"s1\",\"background_tasks\":[$TASKS_SUBAGENT]}"
apply working '{"session_id":"s1"}'
expect "working without field preserves list" \
  '.s1.background_tasks == ["Sleep then reply done"]'

# --- Case 4: empty array clears (key omitted) --------------------------------
new_case c4
apply done "{\"session_id\":\"s1\",\"background_tasks\":[$TASKS_SUBAGENT]}"
apply done '{"session_id":"s1","background_tasks":[]}'
expect "empty array clears the key" '.s1 | has("background_tasks") | not'

# --- Case 5: malformed field preserves the previous value --------------------
new_case c5
apply done "{\"session_id\":\"s1\",\"background_tasks\":[$TASKS_SUBAGENT]}"
apply done '{"session_id":"s1","background_tasks":"nope"}'
expect "malformed field preserves list" \
  '.s1.background_tasks == ["Sleep then reply done"]'

# --- Case 6: non-running tasks are filtered out (result empty -> cleared) ----
new_case c6
apply done "{\"session_id\":\"s1\",\"background_tasks\":[$TASKS_SUBAGENT]}"
apply done '{"session_id":"s1","background_tasks":[{"id":"a1","type":"subagent","status":"completed","description":"x"}]}'
expect "completed tasks filtered, key cleared" '.s1 | has("background_tasks") | not'

# --- Case 7: descriptions sanitized (newlines collapsed, capped at 120) ------
new_case c7
LONG="$(printf 'x%.0s' {1..200})"
apply done "{\"session_id\":\"s1\",\"background_tasks\":[{\"id\":\"c1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"line1\\nline2 $LONG\"}]}"
expect "newline collapsed" '.s1.background_tasks[0] | contains("\n") | not'
expect "capped at 120 chars" '.s1.background_tasks[0] | length <= 120'

# --- Case 8: sessions without the field never gain it -------------------------
new_case c8
apply working '{"session_id":"s1","cwd":"/tmp/p"}'
apply done '{"session_id":"s1"}'
expect "no field anywhere -> key absent" '.s1 | has("background_tasks") | not'

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed."
  exit 1
fi
echo "All background-task cases passed."
