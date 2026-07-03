import Foundation

// Headless tests for ConcurrencyStats: time-weighted averaging, gap
// exclusion, day rollover, retention, persistence.

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("conc-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let fileURL = dir.appendingPathComponent("concurrency.json")

// Local-noon anchor keeps every offset used below inside one local day.
var anchorComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
anchorComponents.hour = 12
let t0 = Calendar.current.date(from: anchorComponents)!

let stats = ConcurrencyStats(url: fileURL)
check("empty initially", stats.todayMax(now: t0) == 0 && stats.todayAverage(now: t0) == nil)

// --- time-weighted average: 2 sessions for 60s, then 3 for 60s -------------------
stats.sample(count: 2, at: t0)
stats.sample(count: 2, at: t0.addingTimeInterval(30))
stats.sample(count: 3, at: t0.addingTimeInterval(60))
stats.sample(count: 3, at: t0.addingTimeInterval(120))
check("max tracked", stats.todayMax(now: t0) == 3)
let average = stats.todayAverage(now: t0)
check("time-weighted average", average != nil && abs(average! - 2.5) < 0.01, "\(String(describing: average))")

// --- gaps longer than 5 minutes are excluded ---------------------------------------
let afterGap = t0.addingTimeInterval(120 + 3600)
stats.sample(count: 1, at: afterGap)
let averageAfterGap = stats.todayAverage(now: afterGap)
check("sleep gap not credited", averageAfterGap != nil && abs(averageAfterGap! - 2.5) < 0.01,
      "\(String(describing: averageAfterGap))")
check("max unchanged by gap", stats.todayMax(now: afterGap) == 3)

// --- persistence across instances -----------------------------------------------------
stats.sample(count: 5, at: afterGap.addingTimeInterval(10)) // max bump forces persist
let reloaded = ConcurrencyStats(url: fileURL)
check("persisted across instances", reloaded.todayMax(now: afterGap) == 5)

// --- day rollover ------------------------------------------------------------------------
let tomorrow = t0.addingTimeInterval(24 * 3600)
stats.sample(count: 1, at: tomorrow)
check("new day starts fresh", stats.todayMax(now: tomorrow) == 1)
check("yesterday still recorded", stats.todayMax(now: t0) == 5)

// --- retention --------------------------------------------------------------------------
let ancient = t0.addingTimeInterval(-40 * 24 * 3600)
let stats2 = ConcurrencyStats(url: dir.appendingPathComponent("retention.json"))
stats2.sample(count: 2, at: ancient)
stats2.sample(count: 4, at: t0) // new day key triggers pruning
check("ancient day pruned", stats2.todayMax(now: ancient) == 0)
check("current day kept", stats2.todayMax(now: t0) == 4)

print(failures == 0 ? "\nAll concurrency tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
