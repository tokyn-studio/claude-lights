import Foundation

// Headless tests for SessionLabels: persistence, sanitizing, and resilience
// against corrupt files. Writes are async (background queue), hence the
// short settles before re-reading from disk.

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

func settle() { Thread.sleep(forTimeInterval: 0.3) }

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("labels-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let fileURL = dir.appendingPathComponent("labels.json")

// --- init creates the file (so the app's watcher can arm immediately) ----------
let labels = SessionLabels(url: fileURL)
check("file created on init", FileManager.default.fileExists(atPath: fileURL.path))
check("empty initially", labels.labels.isEmpty)

// --- set / get / optimistic update ----------------------------------------------
labels.setLabel("  API server  ", for: "s1")
check("label set + trimmed immediately (optimistic)", labels.label(for: "s1") == "API server")
labels.setLabel("Frontend", for: "s2")
settle()

// --- persistence across instances -------------------------------------------------
let second = SessionLabels(url: fileURL)
check("persisted", second.label(for: "s1") == "API server" && second.label(for: "s2") == "Frontend")

// --- blank removes -----------------------------------------------------------------
labels.setLabel("   ", for: "s1")
check("blank clears label", labels.label(for: "s1") == nil)
labels.setLabel(nil, for: "s2")
check("nil clears label", labels.label(for: "s2") == nil)
settle()
check("removal persisted", SessionLabels(url: fileURL).labels.isEmpty)

// --- sanitize ------------------------------------------------------------------------
check("newlines collapsed", SessionLabels.sanitize("a\nb\r\nc") == "a b c")
check("control chars stripped", SessionLabels.sanitize("a\u{07}b\u{1B}[31mc") == "ab[31mc")
check("length capped at 80", SessionLabels.sanitize(String(repeating: "x", count: 500))?.count == 80)
check("blank -> nil", SessionLabels.sanitize("  \n ") == nil)

// --- external writes are sanitized on reload -------------------------------------------
try! #"{"ext-1":"line1\nline2","ext-2":"   ","ext-3":"ok"}"#.data(using: .utf8)!.write(to: fileURL)
labels.reload()
check("external newline label sanitized", labels.label(for: "ext-1") == "line1 line2")
check("external blank label dropped", labels.label(for: "ext-2") == nil)
check("external clean label kept", labels.label(for: "ext-3") == "ok")

// --- corrupt file -> no labels, and writing recovers -------------------------------------
try! "not json".data(using: .utf8)!.write(to: fileURL)
labels.reload()
check("corrupt file yields no labels", labels.labels.isEmpty)
labels.setLabel("recovered", for: "s3")
settle()
check("write after corruption recovers", SessionLabels(url: fileURL).label(for: "s3") == "recovered")

print(failures == 0 ? "\nAll label tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
