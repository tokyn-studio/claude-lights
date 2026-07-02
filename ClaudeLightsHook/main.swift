import Darwin
import Foundation

/// claudelights-hook — merges one Claude Code session's status into the shared
/// status file. Replaces hooks/update-status.sh (no jq, no bash).
///
/// Usage: claudelights-hook <working|resume|compacting|needs_input|done|remove>
///        claudelights-hook --version
///
/// The Claude Code hook payload is read as JSON from stdin. Only the entry for
/// this session's `session_id` is touched; other sessions are never rewritten
/// wholesale. A hook must never block or fail Claude Code, so every error path
/// exits 0 silently.

/// Bumped whenever the wiring or on-disk behavior changes; the app compares it
/// against the bundled helper to drive self-heal ("needs repair").
let helperVersion = "1"

let validStates: Set<String> = ["working", "resume", "compacting", "needs_input", "done", "remove"]

/// Timestamps must decode with the app's plain `.iso8601` strategy: UTC,
/// second precision, no fractional seconds (e.g. "2026-07-02T14:46:36Z").
let iso8601 = ISO8601DateFormatter()

func statusFileURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["CLAUDELIGHTS_STATUS_FILE"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/claudelights-status.json")
}

/// The controlling terminal of this process (e.g. "ttys003"), inherited from
/// the Claude Code session. Native replacement for `ps -o tty= -p $$`.
func controllingTTY() -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 {
        let dev = info.kp_eproc.e_tdev
        if dev != -1, let name = devname(dev, mode_t(S_IFCHR)) {
            let tty = String(cString: name)
            if !tty.isEmpty, tty != "?", tty != "??" { return tty }
        }
    }
    // Fallback: any of the standard descriptors may still be a terminal.
    for fd: Int32 in [0, 1, 2] {
        if let name = ttyname(fd) {
            var tty = String(cString: name)
            if tty.hasPrefix("/dev/") { tty.removeFirst(5) }
            if !tty.isEmpty, tty != "?", tty != "??" { return tty }
        }
    }
    return nil
}

func loadSessions(from url: URL) -> [String: [String: Any]] {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data),
          let map = object as? [String: [String: Any]]
    else { return [:] }
    return map
}

/// Writes to a temp file in the same directory, then atomically renames it
/// into place so readers never observe a half-written file.
func atomicWrite(_ sessions: [String: [String: Any]], to url: URL) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: sessions, options: [.prettyPrinted, .sortedKeys]
    ) else { return }
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
    do {
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
        }
    } catch {
        try? FileManager.default.removeItem(at: tmp)
    }
}

func run() {
    let arguments = CommandLine.arguments.dropFirst()
    if arguments.contains("--version") {
        print(helperVersion)
        return
    }
    guard let state = arguments.first, validStates.contains(state) else {
        FileHandle.standardError.write(Data(
            "usage: claudelights-hook <working|resume|compacting|needs_input|done|remove>\n".utf8))
        return
    }

    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any],
          let sessionId = payload["session_id"] as? String, !sessionId.isEmpty
    else { return }

    let statusURL = statusFileURL()
    let directory = statusURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Serialize concurrent hook invocations (parallel sessions) around the
    // read-modify-write; the legacy shell version had a small race here.
    let lockFD = open(statusURL.path + ".lock", O_CREAT | O_RDWR, 0o644)
    if lockFD >= 0 { flock(lockFD, LOCK_EX) }
    defer {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
    }

    // SessionEnd: remove this session's entry entirely. Like the shell
    // version, a missing or corrupt file is left untouched.
    if state == "remove" {
        guard FileManager.default.fileExists(atPath: statusURL.path) else { return }
        guard let data = try? Data(contentsOf: statusURL),
              (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] != nil
        else { return }
        var sessions = loadSessions(from: statusURL)
        sessions.removeValue(forKey: sessionId)
        atomicWrite(sessions, to: statusURL)
        return
    }

    var sessions = loadSessions(from: statusURL)
    let existing = sessions[sessionId] ?? [:]

    let now = Date()
    let timestamp = iso8601.string(from: now)

    // --- Active-time accounting (excludes time waiting for the user) --------
    //
    //   started         ISO time the CURRENT active stretch began, null if paused
    //   active_seconds  total active seconds banked from finished stretches
    //
    //   working     new turn -> reset accumulator, start stretch
    //   resume      PostToolUse (stored as "working") -> resume if paused
    //   compacting  active continuation
    //   needs_input / done -> bank current stretch, pause (started = null)
    let existingStarted = existing["started"] as? String
    let existingActive = Int((existing["active_seconds"] as? NSNumber)?.doubleValue ?? 0)

    var storedState = state
    var started: String?
    var activeSeconds = existingActive

    switch state {
    case "working":
        activeSeconds = 0
        started = timestamp
    case "resume":
        storedState = "working"
        started = existingStarted ?? timestamp
    case "compacting":
        started = existingStarted ?? timestamp
    default: // needs_input, done
        if let existingStarted, let stretchStart = iso8601.date(from: existingStarted) {
            let elapsed = Int(now.timeIntervalSince1970) - Int(stretchStart.timeIntervalSince1970)
            activeSeconds = existingActive + elapsed
        }
        started = nil
    }

    let cwd = payload["cwd"] as? String
    let project = (cwd?.isEmpty == false) ? (cwd! as NSString).lastPathComponent : nil
    let env = ProcessInfo.processInfo.environment

    var entry: [String: Any] = [
        "state": storedState,
        "session_id": sessionId,
        "project": project ?? NSNull(),
        "term": env["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(),
        "tty": controllingTTY() ?? NSNull(),
        "active_seconds": activeSeconds,
        "started": started ?? NSNull(),
        "timestamp": timestamp,
    ]

    // Best-effort focus/context enrichment; only written when present so the
    // app's re-encode (which drops unknown-nil fields anyway) stays stable.
    if let cwd, !cwd.isEmpty { entry["cwd"] = cwd }
    let enrichment: [(key: String, envVar: String)] = [
        ("bundle_id", "__CFBundleIdentifier"),
        ("tmux_pane", "TMUX_PANE"),
        ("wezterm_pane", "WEZTERM_PANE"),
        ("kitty_window_id", "KITTY_WINDOW_ID"),
        ("kitty_listen_on", "KITTY_LISTEN_ON"),
    ]
    for (key, envVar) in enrichment {
        if let value = env[envVar], !value.isEmpty { entry[key] = value }
    }

    sessions[sessionId] = entry
    atomicWrite(sessions, to: statusURL)
}

// A hook must never fail Claude Code: exit 0 on every path.
run()
exit(0)
