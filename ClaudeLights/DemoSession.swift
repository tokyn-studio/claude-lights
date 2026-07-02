import Foundation

/// Simulates one fake Claude Code session so first-run users see the traffic
/// light work without starting a real session: working → needs input (red icon
/// + sound) → done, then the entry is removed again.
///
/// Writes go through the same read-merge-atomic-write pattern as the hook
/// helper and only ever touch the demo session's own key, so real sessions in
/// the status file are never disturbed. The app's file watcher picks each step
/// up like any real hook event.
final class DemoSessionSimulator {
    private let statusURL: URL
    private let stepInterval: TimeInterval
    private var sessionId: String?
    private var pendingSteps: [DispatchWorkItem] = []

    init(statusURL: URL, stepInterval: TimeInterval = 3) {
        self.statusURL = statusURL
        self.stepInterval = stepInterval
    }

    var isRunning: Bool { sessionId != nil }

    /// Starts the demo cycle. Ignored while a previous cycle is still running.
    func run() {
        guard sessionId == nil else { return }
        let id = "demo-\(UUID().uuidString.prefix(8))"
        sessionId = id

        step(after: 0) { self.write(id: id, state: "working", active: 0, running: true) }
        step(after: stepInterval) {
            self.write(id: id, state: "needs_input", active: Int(self.stepInterval), running: false)
        }
        step(after: stepInterval * 2) {
            self.write(id: id, state: "done", active: Int(self.stepInterval), running: false)
        }
        step(after: stepInterval * 3) {
            self.removeEntry(id: id)
            self.sessionId = nil
            self.pendingSteps = []
        }
    }

    /// Cancels a running demo and removes its entry (used on app termination).
    func cancel() {
        pendingSteps.forEach { $0.cancel() }
        pendingSteps = []
        if let id = sessionId {
            removeEntry(id: id)
            sessionId = nil
        }
    }

    private func step(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        pendingSteps.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Status file mutation (own key only)

    private func write(id: String, state: String, active: Int, running: Bool) {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        var entry: [String: Any] = [
            "state": state,
            "session_id": id,
            "project": String(localized: "Claude demo"),
            "active_seconds": active,
            "started": running ? now : NSNull(),
            "timestamp": now,
        ]
        entry["term"] = NSNull()
        mutate { sessions in sessions[id] = entry }
    }

    private func removeEntry(id: String) {
        mutate { sessions in sessions.removeValue(forKey: id) }
    }

    private func mutate(_ transform: (inout [String: Any]) -> Void) {
        // Take the same lock as the hook helper so a real hook event landing
        // mid-demo is never reverted by our read-modify-write.
        let lockFD = open(statusURL.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }

        var sessions: [String: Any] = [:]
        if let data = try? Data(contentsOf: statusURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sessions = existing
        }
        transform(&sessions)
        guard let data = try? JSONSerialization.data(
            withJSONObject: sessions, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let tmp = statusURL.deletingLastPathComponent()
            .appendingPathComponent(".\(statusURL.lastPathComponent).demo.tmp")
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: tmp)
            _ = rename(tmp.path, statusURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
