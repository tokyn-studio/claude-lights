# Background Tasks in Session State — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show which background tasks (subagents, background Bash) are still running in a session, so a `needs_input`/`done` session that will resume on its own is not mistaken for one blocked on the user.

**Architecture:** The already-wired `Stop` hook payload carries an undocumented `background_tasks` array (verified against Claude Code 2.1.201, see spec `docs/superpowers/specs/2026-07-04-background-tasks-design.md`). The hook helper stores a compact `[String]` of display descriptions in the session entry; the app decodes it into `SessionStatus`, formats a one-line summary, and shows it in the panel row and as a notification-body suffix. No settings.json hook changes.

**Tech Stack:** Swift (swiftc, no Xcode needed for dev), bash+jq test scripts, headless Swift test drivers under `tests/`.

## Global Constraints

- The helper must never block or fail Claude Code: every error path exits 0 silently (existing pattern in `ClaudeLightsHook/main.swift`).
- `background_tasks` is undocumented upstream: absent/malformed payload shapes must leave behavior exactly as today (defensive parsing, preserve last value).
- Bump `helperVersion` from `"1"` to `"2"` (on-disk behavior changes; comment in helper mandates it). App self-heal is SHA-based and needs no change.
- Status-file JSON keys are snake_case; the stored field is `background_tasks` (array of strings).
- User-facing strings: `String(localized:)` in model code, `LocalizedStringKey`/`Text` literals in SwiftUI (existing pattern).
- macOS 13+ (`LSMinimumSystemVersion` 13.0); don't use newer-only APIs.
- Dev build: `scripts/dev-build.sh`; existing test scripts under `scripts/test-*.sh` must keep passing.

---

### Task 1: Hook helper stores `background_tasks`

**Files:**
- Modify: `ClaudeLightsHook/main.swift` (helperVersion line 17; new function; entry construction around line 228)
- Test: `scripts/test-hook-background.sh` (new)

**Interfaces:**
- Consumes: hook JSON payload on stdin; may contain `background_tasks: [{id, type, status, description?, agent_type?, command?}]`.
- Produces: session entry in the status file gains `"background_tasks": [String]` (display descriptions, ≤120 chars each, newlines collapsed). Key is **absent** when nothing is running. Task 2 decodes exactly this shape.

Rules (from the spec):
- Payload field present and parseable → store the mapped list; an empty result **clears** (key omitted).
- Payload field absent or malformed → **preserve** the previous entry's value.
- Only tasks with `status == "running"` (or no status) count; description preferred, then command, then agent_type.

- [ ] **Step 1: Write the failing test script**

Create `scripts/test-hook-background.sh` (mode 755):

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x scripts/test-hook-background.sh && scripts/test-hook-background.sh`
Expected: cases 1–2–3–5–7 FAIL (helper drops the field today); cases 4, 6, 8 PASS trivially.

- [ ] **Step 3: Implement in the helper**

In `ClaudeLightsHook/main.swift`:

3a. Bump the version constant (line 17):

```swift
let helperVersion = "2"
```

3b. Add below `controllingTTY()` (before `loadRoot`):

```swift
/// Display descriptions of still-running background tasks from the hook
/// payload's undocumented `background_tasks` array (Stop payloads carry it;
/// verified against Claude Code 2.1.201). Returns nil when the field is
/// absent or malformed — the caller then preserves the previous value; an
/// empty result means "nothing running" and clears the stored key.
func backgroundTaskSummaries(from payload: [String: Any]) -> [String]? {
    guard let raw = payload["background_tasks"] else { return nil }
    guard let list = raw as? [[String: Any]] else { return nil }
    return list.compactMap { task in
        if let status = task["status"] as? String, status != "running" { return nil }
        let candidates = ["description", "command", "agent_type"]
        guard let value = candidates.lazy
            .compactMap({ task[$0] as? String })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(cleaned.prefix(120))
    }
}
```

3c. In `run()`, after the enrichment `for` loop and before `root[sessionId] = entry`:

```swift
    // Background tasks still running (undocumented Stop-payload field).
    // Absent/malformed payloads keep the last known value — the Stop that
    // precedes an idle_prompt Notification wrote it fresh.
    if let tasks = backgroundTaskSummaries(from: payload) {
        if !tasks.isEmpty { entry["background_tasks"] = tasks }
    } else if let previous = existing["background_tasks"] as? [String], !previous.isEmpty {
        entry["background_tasks"] = previous
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/test-hook-background.sh`
Expected: `All background-task cases passed.`

- [ ] **Step 5: Verify no regression in existing helper tests**

```bash
xcrun swiftc -O -o /tmp/clh-test-helper ClaudeLightsHook/*.swift
scripts/test-hook-parity.sh /tmp/clh-test-helper
```
Expected: `All parity cases passed.` (Parity payloads never contain `background_tasks`, so nothing changes.)

- [ ] **Step 6: Commit**

```bash
git add ClaudeLightsHook/main.swift scripts/test-hook-background.sh
git commit -m "Helper: store still-running background_tasks from hook payloads"
```

---

### Task 2: `SessionStatus` decodes the field and formats the summary

**Files:**
- Modify: `ClaudeLights/Models.swift` (SessionStatus struct, lines 46–99)
- Create: `tests/background/main.swift`
- Create: `scripts/test-background-model.sh`

**Interfaces:**
- Consumes: `"background_tasks": [String]` written by the helper (Task 1).
- Produces: `SessionStatus.backgroundTasks: [String]?` and `SessionStatus.backgroundTasksSummary: String?` — Tasks 3 and 4 read `backgroundTasksSummary`. Summary is non-nil only for `.needsInput`/`.done` with a non-empty list. Codable round-trip preserves the field (this is what keeps `SessionStore.mutateFile`'s re-encode from dropping it — no SessionStore change needed).

- [ ] **Step 1: Write the failing test driver**

Create `tests/background/main.swift`:

```swift
import Foundation

// Headless tests for SessionStatus.backgroundTasks: decoding, summary
// formatting/state-gating, and Codable round-trip (the store re-encodes the
// status file on prune/remove; the field must survive that).

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

func decode(_ json: String) -> SessionStatus? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionStatus.self, from: Data(json.utf8))
}

func session(state: String, tasks: [String]?) -> String {
    var extra = ""
    if let tasks {
        let list = tasks.map { "\"\($0)\"" }.joined(separator: ",")
        extra = ",\"background_tasks\":[\(list)]"
    }
    return #"{"state":"\#(state)","session_id":"s1","project":"demo","timestamp":"2026-07-04T10:00:00Z"\#(extra)}"#
}

// --- decoding -----------------------------------------------------------------
let without = decode(session(state: "needs_input", tasks: nil))
check("decodes without field", without != nil)
check("absent field -> nil", without?.backgroundTasks == nil)
check("absent field -> no summary", without?.backgroundTasksSummary == nil)

let one = decode(session(state: "needs_input", tasks: ["Sleep then reply done"]))
check("decodes list", one?.backgroundTasks == ["Sleep then reply done"])

// --- summary formatting ---------------------------------------------------------
check("singular summary", one?.backgroundTasksSummary == "1 task still running: Sleep then reply done")

let two = decode(session(state: "done", tasks: ["First", "Second"]))
check("plural summary counts and shows first", two?.backgroundTasksSummary == "2 tasks still running: First, …")

let empty = decode(session(state: "needs_input", tasks: []))
check("empty list -> no summary", empty?.backgroundTasksSummary == nil)

// --- state gating ------------------------------------------------------------------
let working = decode(session(state: "working", tasks: ["X"]))
check("working -> no summary", working?.backgroundTasksSummary == nil)
let compacting = decode(session(state: "compacting", tasks: ["X"]))
check("compacting -> no summary", compacting?.backgroundTasksSummary == nil)
check("done -> summary", decode(session(state: "done", tasks: ["X"]))?.backgroundTasksSummary != nil)

// --- Codable round-trip (mutateFile re-encode must not drop the field) -------------
if let one {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(one)
    let reencoded = String(data: data, encoding: .utf8) ?? ""
    check("round-trip keeps background_tasks", reencoded.contains("\"background_tasks\""))
    let roundtripDecoder = JSONDecoder()
    roundtripDecoder.dateDecodingStrategy = .iso8601
    let back = try! roundtripDecoder.decode(SessionStatus.self, from: data)
    check("round-trip keeps values", back.backgroundTasks == ["Sleep then reply done"])
} else {
    check("round-trip (decode failed)", false)
}

print()
if failures > 0 {
    print("\(failures) check(s) failed.")
    exit(1)
}
print("All background-model checks passed.")
```

Create `scripts/test-background-model.sh` (mode 755):

```bash
#!/usr/bin/env bash
#
# Headless tests for SessionStatus background-task decoding and summary
# formatting. Compiles Models.swift with the test driver.
#
# Usage: scripts/test-background-model.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -o "$WORK/bgtest" \
  "$ROOT/ClaudeLights/Models.swift" \
  "$ROOT/tests/background/main.swift"

"$WORK/bgtest"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x scripts/test-background-model.sh && scripts/test-background-model.sh`
Expected: compile FAILURE — `value of type 'SessionStatus' has no member 'backgroundTasks'`.

- [ ] **Step 3: Implement in Models.swift**

3a. Add the stored property after `let pid: Int?` (line 80):

```swift
    /// Display descriptions of background tasks still running in the session
    /// (written by the hook helper from the Stop payload's undocumented
    /// `background_tasks` field). `nil` for older helpers/files.
    let backgroundTasks: [String]?
```

3b. Add to `CodingKeys` (after `case pid`):

```swift
        case backgroundTasks = "background_tasks"
```

3c. Add a computed property after `frozenWorked` (line 150):

```swift
    /// One-line summary of still-running background tasks, shown while the
    /// session waits (`needs_input`/`done`) so a waiting-but-busy session is
    /// not mistaken for one blocked on the user. `nil` while working or
    /// compacting — the session is visibly busy anyway — and when nothing runs.
    var backgroundTasksSummary: String? {
        guard state == .needsInput || state == .done else { return nil }
        guard let backgroundTasks, let first = backgroundTasks.first else { return nil }
        if backgroundTasks.count == 1 {
            return String(localized: "1 task still running: \(first)")
        }
        return String(localized: "\(backgroundTasks.count) tasks still running: \(first), …")
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/test-background-model.sh`
Expected: `All background-model checks passed.`

- [ ] **Step 5: Verify the app still compiles and existing suites pass**

```bash
scripts/dev-build.sh
scripts/test-liveness.sh
```
Expected: `Built and signed.`; liveness suite (compiles `SessionStore.swift` + `Models.swift`) passes.

- [ ] **Step 6: Commit**

```bash
git add ClaudeLights/Models.swift tests/background/main.swift scripts/test-background-model.sh
git commit -m "Model: decode background_tasks and format waiting-summary"
```

---

### Task 3: Panel row shows the summary line

**Files:**
- Modify: `ClaudeLights/PanelView.swift` (SessionRow `rowContent`, lines 203–226)

**Interfaces:**
- Consumes: `session.backgroundTasksSummary: String?` (Task 2). State gating lives there — the view adds no conditions of its own.

- [ ] **Step 1: Add the extra caption line**

In `SessionRow.rowContent`, inside the `VStack(alignment: .leading, spacing: 1)` directly after the state-label `Text` (line 214–216):

```swift
                if let summary = session.backgroundTasksSummary {
                    Text(verbatim: "⏳ \(summary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
```

- [ ] **Step 2: Verify visually with a crafted status file**

```bash
scripts/dev-build.sh --run
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".claude/claudelights-status.json"
data = json.loads(p.read_text()) if p.exists() else {}
data["ui-test-bg"] = {
    "state": "needs_input", "session_id": "ui-test-bg", "project": "bg-demo",
    "term": None, "tty": None, "active_seconds": 42, "started": None,
    "timestamp": "2099-01-01T00:00:00Z",
    "background_tasks": ["Sleep then reply done"],
}
p.write_text(json.dumps(data, indent=2))
EOF
```

Open the menu-bar panel. Expected: row "bg-demo" shows "Needs input" plus a second caption line "⏳ 1 task still running: Sleep then reply done". (Timestamp 2099 keeps it from being pruned as stale; liveness pruning skips it because it has neither pid nor tty.)

Cleanup afterwards:

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / '.claude/claudelights-status.json'
d = json.loads(p.read_text()); d.pop('ui-test-bg', None); p.write_text(json.dumps(d, indent=2))"
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeLights/PanelView.swift
git commit -m "Panel: show still-running background tasks on waiting sessions"
```

---

### Task 4: Notification body gets the suffix

**Files:**
- Modify: `ClaudeLights/NotificationManager.swift` (`notify(session:displayName:)`, lines 45–64)

**Interfaces:**
- Consumes: `session.backgroundTasksSummary: String?` (Task 2). Because the summary is nil for `.working`/`.compacting`, "session starts working" notifications never get a suffix — no extra condition needed.

- [ ] **Step 1: Append the summary to the body**

Replace `content.body = displayName ?? session.displayName` with:

```swift
        var body = displayName ?? session.displayName
        if let summary = session.backgroundTasksSummary {
            body += " — " + summary
        }
        content.body = body
```

- [ ] **Step 2: Verify end-to-end (spike scenario against the dev build)**

With the dev build running and hooks installed (helper self-heals only from the real bundle — for the dev build, copy manually):

```bash
scripts/dev-build.sh --run
cp build/ClaudeLights.app/Contents/Helpers/claudelights-hook \
   "$HOME/Library/Application Support/ClaudeLights/claudelights-hook"
mkdir -p /tmp/clh-e2e && cd /tmp/clh-e2e
claude -p "Use the Agent tool (subagent_type: Explore) with prompt 'Run: sleep 30, then reply done'. Do not wait for it; immediately reply LAUNCHED." --allowedTools "Agent"
```

Expected while the subagent's 30s sleep runs: the panel row for `clh-e2e` shows `Done`/`Needs input` **plus** "⏳ 1 task still running: …", and the desktop notification body carries the " — 1 task still running: …" suffix. After ~30s the session flips back to working, then done, and the extra line disappears. (Dev-build notifications may be limited — the panel line is the authoritative check; notification text can be confirmed on the next release build.)

- [ ] **Step 3: Run the full test-script suite for regressions**

```bash
xcrun swiftc -O -o /tmp/clh-test-helper ClaudeLightsHook/*.swift
scripts/test-hook-parity.sh /tmp/clh-test-helper
scripts/test-hook-background.sh /tmp/clh-test-helper
scripts/test-background-model.sh
scripts/test-hook-installer.sh
scripts/test-liveness.sh
scripts/test-labels.sh
```
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add ClaudeLights/NotificationManager.swift
git commit -m "Notifications: mention still-running background tasks in the body"
```
