import Foundation

/// One recorded state transition, shown in the history view.
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let sessionId: String
    let displayName: String
    let state: SessionState
    let timestamp: Date
}

/// A persisted, rolling log of session state transitions.
///
/// Stored as JSON in Application Support so it survives relaunches. Capped to
/// the most recent `maxEntries` transitions to stay small.
final class SessionHistory: ObservableObject {
    /// Most recent transitions first.
    @Published private(set) var entries: [HistoryEntry] = []

    private let url: URL
    private let maxEntries = 100

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeLights", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        load()
    }

    /// Appends a transition for the given session and persists. Pass the
    /// resolved display name so custom session labels show up here too.
    func record(_ session: SessionStatus, displayName: String? = nil) {
        let entry = HistoryEntry(
            id: UUID(),
            sessionId: session.sessionId,
            displayName: displayName ?? session.displayName,
            state: session.state,
            timestamp: session.timestamp
        )
        // Newest first; trim to the cap.
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    /// Clears the entire history.
    func clear() {
        entries = []
        save()
    }

    /// Total time spent in each state today, derived from consecutive
    /// transitions per session.
    ///
    /// Only *closed* intervals (between two recorded transitions) are counted;
    /// a session's current, still-open state is not counted until it changes.
    /// This reflects observed activity — gaps while the app wasn't running are
    /// naturally excluded.
    func timePerStateToday(now: Date = Date()) -> [SessionState: TimeInterval] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        var result: [SessionState: TimeInterval] = [:]

        let bySession = Dictionary(grouping: entries) { $0.sessionId }
        for (_, list) in bySession {
            let sorted = list.sorted { $0.timestamp < $1.timestamp }
            guard sorted.count > 1 else { continue }
            for index in 0..<(sorted.count - 1) {
                let state = sorted[index].state
                // Clip the interval to today so only today's time counts.
                let start = max(sorted[index].timestamp, startOfToday)
                let end = sorted[index + 1].timestamp
                guard end > start else { continue }
                result[state, default: 0] += end.timeIntervalSince(start)
            }
        }
        return result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
