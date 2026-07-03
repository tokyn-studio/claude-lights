import Foundation

/// Detects which ttys currently host a living `claude` CLI process — and
/// since when — so sessions whose process was killed (SIGKILL never fires the
/// SessionEnd hook) can be cleaned up long before the 2-hour stale expiry.
///
/// Start times matter: macOS recycles pty numbers, so "some claude lives on
/// ttys003" is not enough — a claude that STARTED AFTER a session's last hook
/// event cannot be that session's process (see `SessionStore.pruneDead`).
enum ProcessLiveness {
    /// Start dates of claude processes per tty (e.g. "ttys003"), or nil when
    /// the scan itself failed — callers must treat nil as "don't know" and
    /// skip pruning, never as "everything is dead". A process whose start
    /// time can't be parsed is reported as `.distantPast` (always counts as
    /// old enough — the safe direction).
    static func liveClaudeStarts() -> [String: [Date]]? {
        guard let output = FocusSupport.run("/bin/ps", ["-axo", "tty=,lstart=,command="], timeout: 3) else {
            return nil
        }
        return parseLiveStarts(psOutput: output)
    }

    private static let lstartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// Parses `ps -axo tty=,lstart=,command=` output: tty, five lstart
    /// tokens ("Wed Jul  2 09:03:36 2026"), then the command.
    static func parseLiveStarts(psOutput: String) -> [String: [Date]] {
        var result: [String: [Date]] = [:]
        for line in psOutput.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 7 else { continue }
            let tty = String(tokens[0])
            guard TTYName.isWellFormed(tty) else { continue }
            guard isClaudeCommand(Array(tokens[6...])) else { continue }

            let lstart = tokens[1...5].joined(separator: " ")
            let started = lstartFormatter.date(from: lstart) ?? .distantPast
            result[tty, default: []].append(started)
        }
        return result
    }

    /// Whether `pid` is a live claude CLI process — the precise liveness
    /// check for sessions that carry a pid (agent sessions in editors often
    /// have no tty). Matched by executable PATH, not kernel comm: the
    /// official installer runs versioned binaries
    /// (`~/.local/share/claude/versions/2.1.199`), so comm is the version
    /// number. Keep in sync with isClaudeExecutable in the hook helper.
    /// A recycled pid virtually never lands on another claude, so no
    /// start-time check is needed.
    static func isClaudeProcessAlive(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return (path as NSString).lastPathComponent == "claude" || path.contains("/claude/")
    }

    /// Interpreters through which the claude CLI is commonly launched.
    private static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// True when the tokenized command IS a claude process: the executable
    /// itself, or an interpreter whose first non-flag argument is the claude
    /// script. Arbitrary arguments never count — `vim claude` or
    /// `./deploy.sh claude` must not keep a dead session alive.
    static func isClaudeCommand<S: StringProtocol>(_ tokens: [S]) -> Bool {
        guard let first = tokens.first else { return false }
        // Case-sensitive on purpose: the Electron desktop app's binaries are
        // named "Claude…" and are not CLI sessions.
        if (String(first) as NSString).lastPathComponent == "claude" { return true }
        guard interpreters.contains((String(first) as NSString).lastPathComponent) else { return false }
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") { continue } // interpreter flags
            return (String(token) as NSString).lastPathComponent == "claude"
        }
        return false
    }
}
