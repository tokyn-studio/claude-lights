import Foundation

// Headless tests for dead-session pruning: ps-output parsing and the
// two-consecutive-miss rule in SessionStore.pruneDead.

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

// --- parseLiveTtys ---------------------------------------------------------------
let psOutput = """
ttys001  -zsh
ttys003  /opt/homebrew/bin/node /Users/me/.nvm/versions/node/v22/bin/claude --continue
ttys004  claude
ttys005  /usr/local/bin/claude-lights-helper
??       /Applications/Claude.app/Contents/MacOS/Claude
ttys007  vim notes-about-claude.md
ttys008  /bin/bash ./run.sh claude
"""
let live = ProcessLiveness.parseLiveTtys(psOutput: psOutput)
check("node wrapper detected", live.contains("ttys003"))
check("bare claude detected", live.contains("ttys004"))
check("claude-lights-helper not matched", !live.contains("ttys005"))
check("Desktop app (no tty) ignored", !live.contains("??"))
check("file argument containing claude ignored", !live.contains("ttys007"))
check("shell wrapper third token matched", live.contains("ttys008"))
check("plain shell not matched", !live.contains("ttys001"))

// Real scan must never crash and must return a value on a healthy system.
check("real ps scan returns a set", ProcessLiveness.liveClaudeTtys() != nil)

// --- pruneDead: two-miss rule -------------------------------------------------------
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("liveness-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let statusURL = dir.appendingPathComponent("status.json")

func writeStatus() {
    let json = """
    {"alive":{"state":"working","session_id":"alive","tty":"ttys003","timestamp":"\(iso(Date()))"},
     "dead":{"state":"needs_input","session_id":"dead","tty":"ttys009","timestamp":"\(iso(Date()))"},
     "no-tty":{"state":"working","session_id":"no-tty","timestamp":"\(iso(Date()))"}}
    """
    try! json.data(using: .utf8)!.write(to: statusURL)
}
func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

writeStatus()
let store = SessionStore()
store.reload(from: statusURL)
check("three sessions loaded", store.sessions.count == 3)

let liveSet: Set<String> = ["ttys003"]
check("first miss removes nothing", !store.pruneDead(liveTtys: liveSet, from: statusURL))
store.reload(from: statusURL)
check("still three after first miss", store.sessions.count == 3)

check("second miss removes the dead one", store.pruneDead(liveTtys: liveSet, from: statusURL))
store.reload(from: statusURL)
let ids = Set(store.sessions.map(\.sessionId))
check("alive and no-tty survive", ids == ["alive", "no-tty"], "\(ids)")

// --- miss counter resets when the process reappears -----------------------------------
writeStatus()
store.reload(from: statusURL)
_ = store.pruneDead(liveTtys: ["ttys003"], from: statusURL)          // miss 1 for "dead"
_ = store.pruneDead(liveTtys: ["ttys003", "ttys009"], from: statusURL) // reappears: reset
check("reappearance resets the counter", !store.pruneDead(liveTtys: ["ttys003"], from: statusURL))
store.reload(from: statusURL)
check("session survives non-consecutive misses", store.sessions.count == 3)

print(failures == 0 ? "\nAll liveness tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
