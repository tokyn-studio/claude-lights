import Foundation

/// User-assigned names for sessions, keyed by `session_id` and persisted in
/// `~/.claude/claudelights-labels.json`.
///
/// The file deliberately lives next to the status file in `~/.claude` (not
/// Application Support) so external tooling — e.g. a future `/name-session`
/// slash command — can write it too. Because of that it is treated as
/// untrusted input: every label is sanitized on load as well as on save.
///
/// Labels are never pruned automatically: a session missing from the status
/// snapshot may merely be hidden (row removed) or stale (>2h) and reappear on
/// its next hook event — deleting its name would be silent data loss. The
/// file stays tiny (one short line per named session).
///
/// Disk writes run on a background queue under a NON-blocking flock (same
/// `<file>.lock` convention as the hook helper) so a stuck external writer
/// can never hang the UI; the in-memory value updates optimistically and is
/// reloaded from disk if the write fails.
final class SessionLabels: ObservableObject {
    @Published private(set) var labels: [String: String] = [:]

    private let url: URL
    private let ioQueue = DispatchQueue(label: "studio.vanta.claudelights.labels", qos: .utility)

    /// Exposed so the app can watch the file for external writes.
    var fileURL: URL { url }

    init(url: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.url = url
            ?? env["CLAUDELIGHTS_LABELS_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/claudelights-labels.json")
        ensureFileExists()
        reload()
    }

    func label(for sessionId: String) -> String? {
        labels[sessionId]
    }

    /// Re-reads and sanitizes the file (called on launch and by the file
    /// watcher, main thread). A missing or corrupt file yields no labels.
    func reload() {
        labels = Self.sanitized(readMap())
    }

    /// Sets (or, for nil/blank, removes) the label of one session. The
    /// in-memory value updates immediately; the write happens in the
    /// background and reverts the memory state if it fails.
    func setLabel(_ label: String?, for sessionId: String) {
        let sanitized = label.flatMap(Self.sanitize)
        var updated = labels
        updated[sessionId] = sanitized
        labels = updated

        ioQueue.async { [weak self] in
            guard let self else { return }
            let success = self.writeThrough { map in
                map[sessionId] = sanitized
            }
            if !success {
                DispatchQueue.main.async {
                    NSLog("ClaudeLights: failed to persist session label, reverting")
                    self.reload()
                }
            }
        }
    }

    // MARK: - Sanitizing (the file is world-writable input)

    /// Trims, strips control characters, collapses whitespace/newline runs,
    /// caps the length. Returns nil for labels that end up blank.
    static func sanitize(_ raw: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            CharacterSet.newlines.contains(scalar) ? " " : scalar
        }.filter { !CharacterSet.controlCharacters.contains($0) }))
        let collapsed = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(80))
    }

    private static func sanitized(_ map: [String: String]) -> [String: String] {
        map.compactMapValues(sanitize)
    }

    // MARK: - File I/O

    private func readMap() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return [:] }
        return map
    }

    /// Creates an empty labels file so the app's FileWatcher can arm
    /// immediately instead of retry-polling until the first rename.
    private func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        _ = writeThrough { _ in }
    }

    /// Read-modify-write under a non-blocking flock (bounded retries, ~1s).
    /// Returns false when the lock could not be acquired or the write failed.
    private func writeThrough(_ transform: (inout [String: String]) -> Void) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let lockFD = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        var locked = false
        if lockFD >= 0 {
            for _ in 0..<20 {
                if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                    locked = true
                    break
                }
                usleep(50_000)
            }
        }
        defer {
            if lockFD >= 0 {
                if locked { flock(lockFD, LOCK_UN) }
                close(lockFD)
            }
        }
        guard locked else { return false }

        var map = readMap()
        transform(&map)

        guard let data = try? JSONSerialization.data(
            withJSONObject: map, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try data.write(to: tmp)
            guard rename(tmp.path, url.path) == 0 else {
                try? fileManager.removeItem(at: tmp)
                return false
            }
        } catch {
            try? fileManager.removeItem(at: tmp)
            return false
        }
        return true
    }
}
