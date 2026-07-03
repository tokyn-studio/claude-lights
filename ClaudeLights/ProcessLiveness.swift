import Foundation

/// Detects which ttys currently host a living `claude` CLI process, so
/// sessions whose process was killed (SIGKILL never fires the SessionEnd
/// hook) can be cleaned up long before the 2-hour stale expiry.
enum ProcessLiveness {
    /// ttys (e.g. "ttys003") with a running `claude` process, or nil when the
    /// scan itself failed — callers must treat nil as "don't know" and skip
    /// pruning, never as "everything is dead".
    static func liveClaudeTtys() -> Set<String>? {
        guard let output = FocusSupport.run("/bin/ps", ["-axo", "tty=,command="], timeout: 3) else {
            return nil
        }
        return parseLiveTtys(psOutput: output)
    }

    /// Extracts the ttys of claude processes from `ps -axo tty=,command=`
    /// output. A process counts when any of its first tokens has the exact
    /// basename "claude" — covering direct binaries and interpreter wrappers
    /// like `node …/bin/claude`. Case-sensitive on purpose: the Electron
    /// desktop app's binaries are named "Claude…" and are not CLI sessions
    /// (they carry no tty anyway).
    static func parseLiveTtys(psOutput: String) -> Set<String> {
        var ttys: Set<String> = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let tty = String(trimmed[..<firstSpace])
            guard tty.range(of: "^ttys?[0-9]+$", options: .regularExpression) != nil else { continue }

            let command = trimmed[trimmed.index(after: firstSpace)...]
                .trimmingCharacters(in: .whitespaces)
            let tokens = command.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            let isClaude = tokens.prefix(3).contains { token in
                (token as NSString).lastPathComponent == "claude"
            }
            if isClaude { ttys.insert(tty) }
        }
        return ttys
    }
}
