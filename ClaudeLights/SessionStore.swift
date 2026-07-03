import Foundation

/// Loads, prunes, and exposes the set of known Claude Code sessions.
///
/// The store owns the parsing of the status file plus the two pieces of policy
/// the UI relies on: which single state should color the menu bar icon, and
/// when a session is old enough to be dropped entirely.
final class SessionStore {
    /// Sessions currently considered active, sorted for display (worst first).
    private(set) var sessions: [SessionStatus] = []

    /// Sessions whose state changed since the previous reload (or that are new).
    /// Recomputed on every `reload`. Empty on the first reload so pre-existing
    /// sessions don't trigger notifications at launch.
    private(set) var recentTransitions: [SessionStatus] = []

    /// Last known state per session id, used to detect transitions.
    private var previousStates: [String: SessionState] = [:]
    private var hasSeededStates = false

    /// Liveness-scan misses per session (see `pruneDead`). A miss only counts
    /// as "consecutive" while it is fresh and the session's tty is unchanged.
    private struct DeadMissRecord {
        var tty: String
        var misses: Int
        var lastMiss: Date
    }

    private var deadMisses: [String: DeadMissRecord] = [:]

    /// Sessions not updated within this window are treated as stale and removed
    /// from both the in-memory list and the on-disk file. Defaults to 2 hours.
    private let staleInterval: TimeInterval

    init(staleInterval: TimeInterval = 2 * 60 * 60) {
        self.staleInterval = staleInterval
    }

    /// Re-reads the status file, drops stale sessions (rewriting the file if any
    /// were removed), and refreshes the sorted `sessions` list.
    ///
    /// - Parameters:
    ///   - url: Location of the status JSON file.
    ///   - now: Current time; injectable for testing.
    func reload(from url: URL, now: Date = Date()) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            sessions = []
            recentTransitions = []
            previousStates = [:]
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // A malformed or partially written file should not crash the app; treat
        // it as "no readable sessions" until the next successful write.
        guard var map = try? decoder.decode([String: SessionStatus].self, from: data) else {
            sessions = []
            recentTransitions = []
            return
        }

        // Identify and remove stale entries. The rewrite happens under the
        // status lock (fresh read inside), so a hook firing in between can't
        // be clobbered; the display copy below just drops them locally.
        let staleKeys = map.filter { now.timeIntervalSince($0.value.timestamp) > staleInterval }
            .map(\.key)
        if !staleKeys.isEmpty {
            for key in staleKeys {
                map.removeValue(forKey: key)
            }
            mutateFile(at: url) { onDisk in
                for key in staleKeys where now.timeIntervalSince(onDisk[key]?.timestamp ?? now) > staleInterval {
                    onDisk.removeValue(forKey: key)
                }
            }
        }

        sessions = map.values.sorted { lhs, rhs in
            if lhs.state.severity != rhs.state.severity {
                return lhs.state.severity > rhs.state.severity
            }
            // Most recently updated first within the same state.
            return lhs.timestamp > rhs.timestamp
        }

        updateTransitions()
    }

    /// Diffs the current sessions against the previously seen states and records
    /// which sessions changed. The first reload only seeds the baseline.
    private func updateTransitions() {
        if hasSeededStates {
            recentTransitions = sessions.filter { previousStates[$0.sessionId] != $0.state }
        } else {
            recentTransitions = []
            hasSeededStates = true
        }
        // Rebuild the baseline from the current sessions so removed sessions are
        // forgotten (and won't linger in memory).
        previousStates = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.sessionId, $0.state) }
        )
    }

    /// The highest-severity state across all active sessions, or `nil` if there
    /// are none. Callers map `nil` to the "all clear" (green) icon.
    var worstState: SessionState? {
        sessions.map(\.state).max { $0.severity < $1.severity }
    }

    /// Removes a single session from the status file. The caller should reload
    /// afterwards to refresh the UI.
    func remove(sessionId: String, from url: URL) {
        mutateFile(at: url) { $0.removeValue(forKey: sessionId) }
    }

    /// A miss older than this cannot count as "consecutive" — it may predate
    /// a long gap (pruning toggled off, machine asleep).
    private let missFreshness: TimeInterval = 5 * 60

    /// Removes sessions whose tty no longer hosts a `claude` process that is
    /// OLD ENOUGH to be theirs (a SIGKILLed session never fires SessionEnd
    /// and would otherwise sit red for up to 2 hours). `liveStarts` maps each
    /// tty to the start dates of its claude processes; a process that started
    /// after the session's last hook event cannot be that session — this is
    /// what defeats pty-number recycling. Conservative on purpose:
    /// - only sessions with a well-formed tty are ever considered,
    /// - a session must miss TWO consecutive fresh scans on the SAME tty
    ///   before removal, riding out `ps` races, quick respawns, resumes on a
    ///   new tty, and scan gaps,
    /// - detached tmux panes keep their tty and process, so they survive.
    /// Returns whether anything was removed (caller reloads then).
    func pruneDead(liveStarts: [String: [Date]], now: Date = Date(), from url: URL) -> Bool {
        var toRemove: [String] = []
        for session in sessions {
            // Anchor + aliveness: a captured claude pid is checked directly
            // (works for tty-less editor agent sessions); otherwise fall back
            // to the tty scan.
            let anchor: String
            let alive: Bool
            if let pid = session.pid {
                anchor = "pid:\(pid)"
                alive = ProcessLiveness.isClaudeProcessAlive(pid: pid_t(pid))
            } else if let tty = session.tty, TTYName.isWellFormed(tty) {
                anchor = tty
                // Alive: some claude on this tty started before (or at) the
                // session's last update — small skew tolerance for timestamp
                // rounding in the hooks.
                alive = (liveStarts[tty] ?? []).contains {
                    $0 <= session.timestamp.addingTimeInterval(5)
                }
            } else {
                continue
            }

            if alive {
                deadMisses.removeValue(forKey: session.sessionId)
                continue
            }

            if var record = deadMisses[session.sessionId],
               record.tty == anchor,
               now.timeIntervalSince(record.lastMiss) <= missFreshness {
                record.misses += 1
                record.lastMiss = now
                deadMisses[session.sessionId] = record
                if record.misses >= 2 { toRemove.append(session.sessionId) }
            } else {
                deadMisses[session.sessionId] = DeadMissRecord(tty: anchor, misses: 1, lastMiss: now)
            }
        }
        // Forget counters for sessions that vanished by other means.
        let liveIds = Set(sessions.map(\.sessionId))
        deadMisses = deadMisses.filter { liveIds.contains($0.key) }

        guard !toRemove.isEmpty else { return false }
        mutateFile(at: url) { map in
            for sessionId in toRemove {
                map.removeValue(forKey: sessionId)
            }
        }
        for sessionId in toRemove {
            deadMisses.removeValue(forKey: sessionId)
        }
        return true
    }

    /// Removes all sessions currently in the `done` state from the status file.
    func clearFinished(from url: URL) {
        mutateFile(at: url) { map in
            for (key, value) in map where value.state == .done {
                map.removeValue(forKey: key)
            }
        }
    }

    /// Loads the file, applies `transform`, and writes it back atomically —
    /// under the same `<file>.lock` flock the hook helper serializes on, so a
    /// hook firing mid-rewrite is never clobbered (lost update). The lock is
    /// non-blocking with bounded retries; when it can't be acquired the write
    /// is skipped and the next cycle retries.
    private func mutateFile(at url: URL, _ transform: (inout [String: SessionStatus]) -> Void) {
        let lockFD = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        var locked = false
        if lockFD >= 0 {
            for _ in 0..<10 {
                if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                    locked = true
                    break
                }
                usleep(30_000)
            }
        }
        defer {
            if lockFD >= 0 {
                if locked { flock(lockFD, LOCK_UN) }
                close(lockFD)
            }
        }
        guard locked else { return }

        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var map = try? decoder.decode([String: SessionStatus].self, from: data) else { return }
        transform(&map)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(map) else { return }
        try? encoded.write(to: url, options: .atomic)
    }
}
