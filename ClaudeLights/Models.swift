import Foundation

/// Validation for tty names coming from the world-writable status file or
/// from `ps` output — shared by focusing, liveness, and pruning code.
enum TTYName {
    /// "ttys003"-style device names; anything else is treated as absent.
    static func isWellFormed(_ name: String) -> Bool {
        name.range(of: "^ttys?[0-9]+$", options: .regularExpression) != nil
    }
}

/// The lifecycle state a Claude Code session reports through its hooks.
///
/// The raw values match the strings written into the status file by the hook
/// scripts, so the same enum can be used for decoding without a custom mapping.
enum SessionState: String, Codable, CaseIterable {
    /// Claude Code is actively processing a prompt.
    case working
    /// Claude Code is compacting the conversation context (PreCompact hook).
    case compacting
    /// Claude Code finished and is waiting for a new prompt.
    case done
    /// Claude Code needs the user (permission prompt, question, idle prompt).
    case needsInput = "needs_input"

    /// Relative importance used to pick the "worst" state across all sessions.
    ///
    /// A higher value wins, so the menu bar reflects the most attention-worthy
    /// session: `needs_input` > `working` > `compacting` > `done`. Both
    /// `working` and `compacting` mean "busy, no action needed".
    var severity: Int {
        switch self {
        case .done: return 0
        case .compacting: return 1
        case .working: return 2
        case .needsInput: return 3
        }
    }
}

/// One session's status as persisted in `~/.claude/claudelights-status.json`.
///
/// The file is a JSON object keyed by `session_id`; each value decodes into one
/// of these structs. `CodingKeys` bridges Swift's camelCase to the snake_case
/// keys written by the shell hooks.
struct SessionStatus: Codable {
    let state: SessionState
    let sessionId: String
    /// A human-friendly project name (usually the basename of the session cwd).
    let project: String?
    /// The terminal the session runs in (from `TERM_PROGRAM`), if captured.
    /// Optional so older status files without the field still decode.
    let term: String?
    /// The session's controlling tty (e.g. "ttys003"), if captured. Used to
    /// focus the exact terminal window/tab.
    let tty: String?
    /// Start of the CURRENT active stretch, or `nil` while paused (needs_input)
    /// or done. Optional so older files still decode.
    let started: Date?
    /// Active work seconds accumulated from finished stretches (excludes time
    /// spent waiting for the user). `nil` for older files.
    let activeSeconds: Double?
    /// When this entry was last updated. Used for stale-session cleanup.
    let timestamp: Date
    /// Full working directory of the session, if captured.
    let cwd: String?
    /// Bundle id of the hosting app (from `__CFBundleIdentifier`), if captured.
    /// Identifies the terminal/IDE even when `TERM_PROGRAM` is absent.
    let bundleId: String?
    /// tmux pane id (e.g. "%5"), if the session runs inside tmux.
    let tmuxPane: String?
    /// WezTerm pane id, if the session runs inside WezTerm.
    let weztermPane: String?
    /// kitty window id, if the session runs inside kitty.
    let kittyWindowId: String?
    /// kitty remote-control socket (from `KITTY_LISTEN_ON`), if configured.
    let kittyListenOn: String?
    /// PID of the session's claude CLI process, if the hook could identify
    /// it. Used for exact in-editor terminal focusing and pid-based liveness.
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case sessionId = "session_id"
        case project
        case term
        case tty
        case started
        case activeSeconds = "active_seconds"
        case timestamp
        case cwd
        case bundleId = "bundle_id"
        case tmuxPane = "tmux_pane"
        case weztermPane = "wezterm_pane"
        case kittyWindowId = "kitty_window_id"
        case kittyListenOn = "kitty_listen_on"
        case pid
    }

    /// A short, stable label for the session when no project name is available.
    var shortSessionId: String {
        String(sessionId.prefix(8))
    }

    /// The best display name available: project name, else a shortened id.
    var displayName: String {
        if let project, !project.isEmpty {
            return project
        }
        return shortSessionId
    }

    /// A `done` session that has been idle (untouched) longer than `threshold`
    /// is considered "idle" — a display-only distinction from a fresh `done`.
    func isIdle(now: Date = Date(), threshold: TimeInterval = 600) -> Bool {
        state == .done && now.timeIntervalSince(timestamp) > threshold
    }

    /// Whether the work timer is currently running (a stretch is in progress).
    /// `needs_input`/`done` are paused, so the timer freezes — like the terminal.
    var isActive: Bool {
        guard started != nil else { return false }
        switch state {
        case .working, .compacting: return true
        case .done, .needsInput: return false
        }
    }

    /// Reference date for a live count-up timer, chosen so that
    /// `now - reference == accumulated + (now - started)` = total active time.
    /// `nil` when not active.
    var timerReference: Date? {
        guard isActive, let started else { return nil }
        return started.addingTimeInterval(-(activeSeconds ?? 0))
    }

    /// Frozen total active work time, shown while paused or done. Falls back to
    /// `timestamp - started` for older entries that predate `active_seconds`.
    var frozenWorked: TimeInterval? {
        if let activeSeconds { return activeSeconds }
        if let started { return max(0, timestamp.timeIntervalSince(started)) }
        return nil
    }
}
