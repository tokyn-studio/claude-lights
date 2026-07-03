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

    /// Consecutive liveness-scan misses per session (see `pruneDead`).
    private var deadMissCounts: [String: Int] = [:]

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

        // Identify and remove stale entries.
        let staleKeys = map.filter { now.timeIntervalSince($0.value.timestamp) > staleInterval }
            .map(\.key)
        if !staleKeys.isEmpty {
            for key in staleKeys {
                map.removeValue(forKey: key)
            }
            persist(map, to: url)
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

    /// Removes sessions whose tty no longer hosts a living `claude` process
    /// (a SIGKILLed session never fires SessionEnd and would otherwise sit
    /// red for up to 2 hours). Conservative on purpose:
    /// - only sessions with a well-formed tty are ever considered,
    /// - a session must miss TWO consecutive scans before removal, riding
    ///   out `ps` races and quick respawns,
    /// - detached tmux panes keep their tty and process, so they survive.
    /// Returns whether anything was removed (caller reloads then).
    func pruneDead(liveTtys: Set<String>, from url: URL) -> Bool {
        var toRemove: [String] = []
        for session in sessions {
            guard let tty = session.tty,
                  tty.range(of: "^ttys?[0-9]+$", options: .regularExpression) != nil
            else { continue }
            if liveTtys.contains(tty) {
                deadMissCounts.removeValue(forKey: session.sessionId)
            } else {
                let misses = (deadMissCounts[session.sessionId] ?? 0) + 1
                deadMissCounts[session.sessionId] = misses
                if misses >= 2 { toRemove.append(session.sessionId) }
            }
        }
        // Forget counters for sessions that vanished by other means.
        let liveIds = Set(sessions.map(\.sessionId))
        deadMissCounts = deadMissCounts.filter { liveIds.contains($0.key) }

        guard !toRemove.isEmpty else { return false }
        mutateFile(at: url) { map in
            for sessionId in toRemove {
                map.removeValue(forKey: sessionId)
            }
        }
        for sessionId in toRemove {
            deadMissCounts.removeValue(forKey: sessionId)
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

    /// Loads the file, applies `transform`, and writes it back atomically.
    private func mutateFile(at url: URL, _ transform: (inout [String: SessionStatus]) -> Void) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var map = try? decoder.decode([String: SessionStatus].self, from: data) else { return }
        transform(&map)
        persist(map, to: url)
    }

    /// Atomically writes the pruned session map back to disk.
    private func persist(_ map: [String: SessionStatus], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
