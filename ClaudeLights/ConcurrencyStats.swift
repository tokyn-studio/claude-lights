import Foundation

/// How many sessions ran in parallel, per day: the daily maximum and a
/// time-weighted average, persisted in Application Support.
///
/// `sample(count:at:)` is fed from every reload; the interval since the
/// previous sample is credited at the PREVIOUS count (step function). Gaps
/// longer than `maxGap` — app not running, machine asleep — are excluded
/// from the average rather than counted as zeros. Days roll over at local
/// midnight; the sliver of an interval that spans midnight is simply not
/// credited (not worth the complexity).
final class ConcurrencyStats: ObservableObject {
    struct DayStats: Codable, Equatable {
        var maxConcurrent: Int
        /// Σ (count × seconds) over observed intervals.
        var weightedSum: Double
        var observedSeconds: Double
        var lastCount: Int
        var lastSample: Date
    }

    @Published private(set) var days: [String: DayStats] = [:]

    private let url: URL
    private let maxGap: TimeInterval = 5 * 60
    private let retentionDays = 30
    private let persistInterval: TimeInterval = 30
    private var lastPersist: Date = .distantPast

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd" // local time zone: a "day" is the user's day
        return formatter
    }()

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClaudeLights", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.url = base.appendingPathComponent("concurrency.json")
        }
        load()
    }

    /// Records the current number of parallel sessions. Call from the main
    /// thread (reload path); persistence is throttled to every 30s unless the
    /// daily maximum moved.
    func sample(count: Int, at now: Date = Date()) {
        let key = dayFormatter.string(from: now)
        var maxMoved = false

        if var day = days[key] {
            let elapsed = now.timeIntervalSince(day.lastSample)
            if elapsed > 0, elapsed <= maxGap {
                day.weightedSum += Double(day.lastCount) * elapsed
                day.observedSeconds += elapsed
            }
            if count > day.maxConcurrent {
                day.maxConcurrent = count
                maxMoved = true
            }
            day.lastCount = count
            day.lastSample = now
            days[key] = day
        } else {
            days[key] = DayStats(
                maxConcurrent: count, weightedSum: 0, observedSeconds: 0,
                lastCount: count, lastSample: now)
            maxMoved = true
            pruneOldDays(now: now)
        }

        if maxMoved || now.timeIntervalSince(lastPersist) >= persistInterval {
            persist()
            lastPersist = now
        }
    }

    /// Highest number of parallel sessions seen today.
    func todayMax(now: Date = Date()) -> Int {
        days[dayFormatter.string(from: now)]?.maxConcurrent ?? 0
    }

    /// Time-weighted average parallel sessions today, or nil while less than
    /// a minute has been observed (an average of one sample is noise).
    func todayAverage(now: Date = Date()) -> Double? {
        guard let day = days[dayFormatter.string(from: now)],
              day.observedSeconds >= 60
        else { return nil }
        return day.weightedSum / day.observedSeconds
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        days = (try? decoder.decode([String: DayStats].self, from: data)) ?? [:]
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(days) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func pruneOldDays(now: Date) {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let cutoff = dayFormatter.string(from: cutoffDate)
        // Keys are yyyy-MM-dd, so string comparison is date comparison.
        days = days.filter { $0.key >= cutoff }
    }
}
