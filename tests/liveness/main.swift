import Foundation

// Headless tests for dead-session pruning: ps-output parsing (with process
// start times), command classification, tty recycling, and the
// two-consecutive-fresh-miss rule in SessionStore.pruneDead.

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

// --- isClaudeCommand -------------------------------------------------------------
func tokens(_ s: String) -> [Substring] { s.split(separator: " ") }
check("bare claude", ProcessLiveness.isClaudeCommand(tokens("claude")))
check("absolute path", ProcessLiveness.isClaudeCommand(tokens("/opt/homebrew/bin/claude --continue")))
check("node wrapper", ProcessLiveness.isClaudeCommand(tokens("/usr/local/bin/node /Users/x/bin/claude")))
check("node wrapper with flags",
      ProcessLiveness.isClaudeCommand(tokens("node --no-warnings --enable-source-maps /x/bin/claude")))
check("bun wrapper", ProcessLiveness.isClaudeCommand(tokens("bun /x/bin/claude")))
check("shell wrapper argument NOT matched", !ProcessLiveness.isClaudeCommand(tokens("/bin/bash ./run.sh claude")))
check("vim with claude file NOT matched", !ProcessLiveness.isClaudeCommand(tokens("vim claude")))
check("claude-lights-helper NOT matched", !ProcessLiveness.isClaudeCommand(tokens("/usr/local/bin/claude-lights-helper")))
check("Desktop app binary NOT matched",
      !ProcessLiveness.isClaudeCommand(tokens("/Applications/Claude.app/Contents/MacOS/Claude")))
check("login shell NOT matched", !ProcessLiveness.isClaudeCommand(tokens("-zsh")))
check("node with non-claude script NOT matched", !ProcessLiveness.isClaudeCommand(tokens("node /x/server.js claude")))

// --- parseLiveStarts ----------------------------------------------------------------
let psOutput = """
ttys001  Wed Jul  1 08:00:00 2026 -zsh
ttys003  Wed Jul  1 09:03:36 2026 /opt/homebrew/bin/node /Users/me/bin/claude --continue
ttys004  Thu Jul  2 10:15:00 2026 claude
??       Wed Jul  1 08:00:00 2026 /Applications/Claude.app/Contents/MacOS/Claude
ttys007  Wed Jul  1 08:00:00 2026 vim notes-about-claude.md
"""
let starts = ProcessLiveness.parseLiveStarts(psOutput: psOutput)
check("wrapper tty parsed", starts["ttys003"]?.count == 1)
check("bare claude tty parsed", starts["ttys004"]?.count == 1)
check("shell/vim/desktop ignored",
      starts["ttys001"] == nil && starts["ttys007"] == nil && starts.count == 2, "\(starts.keys)")

let lstartFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter
}()
let expected = lstartFormatter.date(from: "Wed Jul 1 09:03:36 2026")!
check("lstart parsed correctly", starts["ttys003"]?.first == expected)

// Real scan must never crash and must return a value on a healthy system.
check("real ps scan returns a map", ProcessLiveness.liveClaudeStarts() != nil)

// --- pruneDead --------------------------------------------------------------------
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("liveness-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let statusURL = dir.appendingPathComponent("status.json")

let iso = ISO8601DateFormatter()
let now = iso.date(from: "2026-07-03T12:00:00Z")!
let sessionUpdated = iso.date(from: "2026-07-03T11:00:00Z")!

func writeStatus() {
    let stamp = iso.string(from: sessionUpdated)
    let json = """
    {"alive":{"state":"working","session_id":"alive","tty":"ttys003","timestamp":"\(stamp)"},
     "dead":{"state":"needs_input","session_id":"dead","tty":"ttys009","timestamp":"\(stamp)"},
     "no-tty":{"state":"working","session_id":"no-tty","timestamp":"\(stamp)"}}
    """
    try! json.data(using: .utf8)!.write(to: statusURL)
}

let oldStart = sessionUpdated.addingTimeInterval(-3600) // predates the session: could be its process
let newStart = sessionUpdated.addingTimeInterval(600)   // started after the last hook: recycled tty

writeStatus()
let store = SessionStore()
store.reload(from: statusURL, now: now)
check("three sessions loaded", store.sessions.count == 3)

let live: [String: [Date]] = ["ttys003": [oldStart]]
check("first miss removes nothing", !store.pruneDead(liveStarts: live, now: now, from: statusURL))
store.reload(from: statusURL, now: now)
check("still three after first miss", store.sessions.count == 3)

check("second miss removes the dead one",
      store.pruneDead(liveStarts: live, now: now.addingTimeInterval(60), from: statusURL))
store.reload(from: statusURL, now: now)
check("alive and no-tty survive", Set(store.sessions.map(\.sessionId)) == ["alive", "no-tty"])

// --- tty recycling: a claude that started AFTER the session is not its process ------
writeStatus()
let store2 = SessionStore()
store2.reload(from: statusURL, now: now)
let recycled: [String: [Date]] = ["ttys003": [oldStart], "ttys009": [newStart]]
_ = store2.pruneDead(liveStarts: recycled, now: now, from: statusURL)
check("recycled tty still removes the zombie",
      store2.pruneDead(liveStarts: recycled, now: now.addingTimeInterval(60), from: statusURL))

// --- reappearance resets the counter --------------------------------------------------
writeStatus()
let store3 = SessionStore()
store3.reload(from: statusURL, now: now)
_ = store3.pruneDead(liveStarts: live, now: now, from: statusURL)                       // miss 1
let revived: [String: [Date]] = ["ttys003": [oldStart], "ttys009": [oldStart]]
_ = store3.pruneDead(liveStarts: revived, now: now.addingTimeInterval(60), from: statusURL) // alive again
check("reappearance resets the counter",
      !store3.pruneDead(liveStarts: live, now: now.addingTimeInterval(120), from: statusURL))

// --- stale misses don't count as consecutive -------------------------------------------
writeStatus()
let store4 = SessionStore()
store4.reload(from: statusURL, now: now)
_ = store4.pruneDead(liveStarts: live, now: now, from: statusURL)                       // miss 1
check("miss after a long gap starts over",
      !store4.pruneDead(liveStarts: live, now: now.addingTimeInterval(3600), from: statusURL))

// --- pid-based liveness (sessions without a tty, e.g. editor agent sessions) ---
check("pid 1 is not claude", !ProcessLiveness.isClaudeProcessAlive(pid: 1))

// A freshly built sleeper under a .../claude/versions/ path (mirrors the
// official installer layout; matches the path rule). Deliberately NOT a
// copied system binary — those can wedge uninterruptibly in dyld and hang
// the whole test in waitUntilExit.
if CommandLine.arguments.count > 1 {
    let waiterPath = CommandLine.arguments[1]
    let fake = Process()
    fake.executableURL = URL(fileURLWithPath: waiterPath)
    try! fake.run()
    let fakePid = fake.processIdentifier
    Thread.sleep(forTimeInterval: 0.3)
    check("live claude-path process detected", ProcessLiveness.isClaudeProcessAlive(pid: fakePid))

    let stamp = iso.string(from: sessionUpdated)
    let json = """
    {"agent":{"state":"needs_input","session_id":"agent","pid":\(fakePid),"timestamp":"\(stamp)"}}
    """
    try! json.data(using: .utf8)!.write(to: statusURL)

    let store5 = SessionStore()
    store5.reload(from: statusURL, now: now)
    check("pid session survives while process lives",
          !store5.pruneDead(liveStarts: [:], now: now, from: statusURL)
          && !store5.pruneDead(liveStarts: [:], now: now.addingTimeInterval(60), from: statusURL))

    kill(fakePid, SIGKILL)
    fake.waitUntilExit()
    check("dead claude-path process detected", !ProcessLiveness.isClaudeProcessAlive(pid: fakePid))
    _ = store5.pruneDead(liveStarts: [:], now: now.addingTimeInterval(120), from: statusURL)   // miss 1
    check("pid session removed after two misses",
          store5.pruneDead(liveStarts: [:], now: now.addingTimeInterval(180), from: statusURL))
    store5.reload(from: statusURL, now: now)
    check("pid session gone from file", store5.sessions.isEmpty)
} else {
    print("SKIP: pid-liveness process tests (no waiter binary passed)")
}

print(failures == 0 ? "\nAll liveness tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
