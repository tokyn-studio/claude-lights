import Combine
import CryptoKit
import Foundation

/// How ClaudeLights' hook wiring in `~/.claude/settings.json` currently looks.
enum HookInstallStatus: Equatable {
    enum RepairReason: Equatable {
        /// The helper binary referenced from settings.json is gone.
        case helperMissing
        /// The installed helper differs from the one bundled with this app.
        case helperOutdated
        /// Some of our hook events are wired, but not all of them.
        case partialWiring
        /// Our entries point somewhere other than the expected helper path
        /// (e.g. a previous install location).
        case wrongPath
    }

    case unknown
    case notInstalled
    case installed
    case needsRepair(RepairReason)
    /// The old jq-based shell scripts from the repository are wired up.
    case legacyShellHooks
    /// settings.json exists but is not strict JSON (comments, trailing
    /// commas, …). We never write in this state.
    case settingsUnreadable(String)
}

enum HookInstallError: LocalizedError {
    case settingsUnreadable(String)
    case bundledHelperMissing
    case helperInstallFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .settingsUnreadable(let detail):
            return String(localized: "settings.json could not be parsed (\(detail)). Fix it manually, then try again.")
        case .bundledHelperMissing:
            return String(localized: "The hook helper is missing from the app bundle. Reinstall ClaudeLights.")
        case .helperInstallFailed(let path):
            return String(localized: "Could not install the hook helper to \(path). Check disk space and permissions, then try again.")
        case .writeFailed(let detail):
            return String(localized: "Could not write settings.json (\(detail)).")
        }
    }
}

/// Installs, repairs, and removes the Claude Code hook wiring.
///
/// The helper binary is copied out of the app bundle to a stable location
/// (`~/Library/Application Support/ClaudeLights/`) so the wiring in
/// settings.json survives app updates, relocation, and App Translocation.
/// `ensureHelperCurrent()` re-copies it whenever the bundled helper changes.
final class HookInstaller: ObservableObject {
    @Published private(set) var status: HookInstallStatus = .unknown

    /// One wired hook event: `'<helper>' <verb>` under `event`, optionally
    /// restricted by a matcher (Claude Code's per-event filter).
    private struct Wiring {
        let event: String
        let verb: String
        let matcher: String?
    }

    private static let wirings: [Wiring] = [
        Wiring(event: "UserPromptSubmit", verb: "working", matcher: nil),
        Wiring(event: "PostToolUse", verb: "resume", matcher: nil),
        Wiring(event: "Stop", verb: "done", matcher: nil),
        Wiring(event: "PreCompact", verb: "compacting", matcher: nil),
        Wiring(event: "Notification", verb: "needs_input", matcher: "idle_prompt|permission_prompt"),
        Wiring(event: "SessionEnd", verb: "remove", matcher: nil),
    ]

    static let helperName = "claudelights-hook"
    private static let backupPrefix = "settings.json.claudelights-backup-"
    private static let keptBackups = 3

    private let settingsURL: URL
    private let helperDirectory: URL
    private let bundledHelperURL: URL
    private let fileManager = FileManager.default

    /// - Parameters:
    ///   - settingsURL: Claude Code's settings file. Defaults to
    ///     `~/.claude/settings.json`; override with `CLAUDELIGHTS_SETTINGS_FILE`
    ///     (also the escape hatch for `CLAUDE_CONFIG_DIR` setups, which a GUI
    ///     app cannot see).
    ///   - helperDirectory: Where the helper is installed. Defaults to
    ///     `~/Library/Application Support/ClaudeLights`; override with
    ///     `CLAUDELIGHTS_HELPER_DIR`.
    ///   - bundledHelperURL: The helper inside the app bundle.
    init(settingsURL: URL? = nil, helperDirectory: URL? = nil, bundledHelperURL: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.settingsURL = settingsURL
            ?? env["CLAUDELIGHTS_SETTINGS_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        self.helperDirectory = helperDirectory
            ?? env["CLAUDELIGHTS_HELPER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/ClaudeLights")
        self.bundledHelperURL = bundledHelperURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(Self.helperName)")
    }

    private var installedHelperURL: URL {
        helperDirectory.appendingPathComponent(Self.helperName)
    }

    /// The settings file this installer reads and writes (for "open in editor").
    var settingsFileURL: URL { settingsURL }

    // MARK: - Status detection

    /// Does this hook command belong to us (current helper wiring)?
    private func isOurCommand(_ command: String) -> Bool {
        command.contains(Self.helperName)
    }

    /// The event wrapper scripts shipped in the repository's `hooks/` folder.
    private static let legacyScriptNames = [
        "working.sh", "resume.sh", "done.sh", "compacting.sh",
        "needs_input.sh", "ended.sh", "update-status.sh",
    ]

    /// Does this hook command point at the deprecated shell scripts? Matched
    /// by `hooks/<script>` rather than the repo folder name, so clones and
    /// downloads in renamed directories (e.g. `claude-lights-main`) are
    /// recognized and migrated too.
    private func isLegacyCommand(_ command: String) -> Bool {
        Self.legacyScriptNames.contains { command.contains("/hooks/\($0)") }
    }

    /// POSIX single-quoting that survives quotes inside the path itself
    /// (`/Users/o'brien/…`).
    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command written into settings.json. The existence guard makes the
    /// hook a silent no-op if the helper is ever removed without uninstalling
    /// the wiring (e.g. `brew uninstall --zap`), instead of failing every
    /// Claude Code event.
    private func hookCommand(verb: String) -> String {
        let quoted = shellQuote(installedHelperURL.path)
        return "[ -x \(quoted) ] && \(quoted) \(verb) || true"
    }

    func refreshStatus() {
        status = detectStatus()
    }

    private func detectStatus() -> HookInstallStatus {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return .notInstalled }
        let settings: [String: Any]
        do {
            settings = try readSettings()
        } catch {
            return .settingsUnreadable(error.localizedDescription)
        }

        var ourCommands: [String] = []
        var wiredEvents: Set<String> = []
        var hasLegacy = false
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let command = hook["command"] as? String else { continue }
                    if isOurCommand(command) {
                        ourCommands.append(command)
                        wiredEvents.insert(event)
                    } else if isLegacyCommand(command) {
                        hasLegacy = true
                    }
                }
            }
        }

        if ourCommands.isEmpty {
            return hasLegacy ? .legacyShellHooks : .notInstalled
        }
        if hasLegacy { return .legacyShellHooks }

        // Manual wiring per settings.snippet.json uses "$HOME/..."; the shell
        // expands it to the same helper, so treat it as the correct path.
        let homeRelativePath = installedHelperURL.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
        if !ourCommands.allSatisfy({
            $0.contains(installedHelperURL.path) || $0.contains(homeRelativePath)
        }) {
            return .needsRepair(.wrongPath)
        }
        if wiredEvents != Set(Self.wirings.map(\.event)) {
            return .needsRepair(.partialWiring)
        }
        guard fileManager.fileExists(atPath: installedHelperURL.path) else {
            return .needsRepair(.helperMissing)
        }
        if let bundled = sha256(of: bundledHelperURL),
           sha256(of: installedHelperURL) != bundled {
            return .needsRepair(.helperOutdated)
        }
        return .installed
    }

    // MARK: - Helper binary self-heal

    /// Copies the bundled helper to the stable install location when it is
    /// missing or differs (i.e. after every app update). Safe to call on every
    /// launch; does nothing when there is no bundled helper (dev builds
    /// without the Helpers folder) or nothing to update.
    func ensureHelperCurrent() {
        guard fileManager.fileExists(atPath: bundledHelperURL.path) else { return }
        let installed = installedHelperURL
        if let bundled = sha256(of: bundledHelperURL), sha256(of: installed) == bundled {
            return
        }
        do {
            try fileManager.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: installed.path) {
                try fileManager.removeItem(at: installed)
            }
            try fileManager.copyItem(at: bundledHelperURL, to: installed)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        } catch {
            NSLog("ClaudeLights: failed to install hook helper: \(error.localizedDescription)")
        }
    }

    private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install / uninstall

    /// Installs (or repairs/migrates) the hook wiring. Idempotent: existing
    /// ClaudeLights entries — current helper or legacy shell scripts — are
    /// replaced; everything else in settings.json is preserved.
    func install() throws {
        guard fileManager.fileExists(atPath: bundledHelperURL.path) else {
            throw HookInstallError.bundledHelperMissing
        }
        ensureHelperCurrent()
        // Never wire settings.json to a helper that failed to install.
        guard fileManager.isExecutableFile(atPath: installedHelperURL.path) else {
            throw HookInstallError.helperInstallFailed(helperDirectory.path)
        }

        var settings = try readSettingsOrEmpty()

        // Refuse to rewrite structures we don't understand rather than
        // guessing and losing someone else's configuration.
        if let hooksValue = settings["hooks"], !(hooksValue is [String: Any]) {
            throw HookInstallError.settingsUnreadable("\"hooks\" is not an object")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for wiring in Self.wirings {
            if let value = hooks[wiring.event], !(value is [Any]) {
                throw HookInstallError.settingsUnreadable("hooks.\(wiring.event) is not an array")
            }
        }

        try backupSettingsIfPresent()

        for wiring in Self.wirings {
            var groups = removingOurEntries(from: hooks[wiring.event])
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand(verb: wiring.verb)]],
            ]
            if let matcher = wiring.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[wiring.event] = groups
        }
        settings["hooks"] = hooks

        try writeSettings(settings)
        refreshStatus()
    }

    /// Removes only ClaudeLights' hook entries (current and legacy), cleaning
    /// up structures that become empty. Leaves the helper binary in place.
    func uninstall() throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            refreshStatus()
            return
        }
        var settings = try readSettings()
        try backupSettingsIfPresent()

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in hooks.keys {
            let cleaned = removingOurEntries(from: hooks[event])
            // Leave events we didn't actually change byte-identical (including
            // shapes we don't understand and foreign empty arrays).
            if let original = hooks[event] as? NSArray, original.isEqual(to: cleaned) {
                continue
            }
            guard hooks[event] is [Any] else { continue }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        try writeSettings(settings)
        refreshStatus()
    }

    /// Strips our commands (current helper and legacy scripts) out of one
    /// event's matcher groups. Groups whose shape we don't recognize are kept
    /// verbatim — this must never delete configuration we don't own — and a
    /// group is only dropped when removing our hooks left it empty.
    private func removingOurEntries(from value: Any?) -> [Any] {
        var result: [Any] = []
        for element in value as? [Any] ?? [] {
            guard var group = element as? [String: Any],
                  let hookList = group["hooks"] as? [[String: Any]]
            else {
                result.append(element)
                continue
            }
            let kept = hookList.filter { hook in
                guard let command = hook["command"] as? String else { return true }
                return !isOurCommand(command) && !isLegacyCommand(command)
            }
            if kept.isEmpty, kept.count != hookList.count { continue }
            group["hooks"] = kept
            result.append(group)
        }
        return result
    }

    // MARK: - settings.json I/O

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookInstallError.settingsUnreadable("top level is not an object")
            }
            return object
        } catch let error as HookInstallError {
            throw error
        } catch {
            // Strict JSON only: comments or trailing commas land here, and we
            // must never rewrite (and thereby mangle) such a file.
            throw HookInstallError.settingsUnreadable(error.localizedDescription)
        }
    }

    private func readSettingsOrEmpty() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        return try readSettings()
    }

    /// The file we actually write: symlinks are resolved so dotfiles setups
    /// keep their link instead of having it replaced by a plain file.
    private var writeTargetURL: URL {
        settingsURL.resolvingSymlinksInPath()
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw HookInstallError.writeFailed(error.localizedDescription)
        }
        let target = writeTargetURL
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Preserve the file's permissions (settings.json can hold secrets
            // like apiKeyHelper output; a chmod 600 must survive the rewrite).
            let existingPermissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
            let tmp = target.deletingLastPathComponent()
                .appendingPathComponent(".\(target.lastPathComponent).claudelights.tmp")
            try data.write(to: tmp)
            try fileManager.setAttributes(
                [.posixPermissions: existingPermissions ?? NSNumber(value: 0o600)],
                ofItemAtPath: tmp.path)
            guard rename(tmp.path, target.path) == 0 else {
                try? fileManager.removeItem(at: tmp)
                throw HookInstallError.writeFailed(String(cString: strerror(errno)))
            }
        } catch let error as HookInstallError {
            throw error
        } catch {
            throw HookInstallError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Backups

    private func backupSettingsIfPresent() throws {
        let target = writeTargetURL
        guard fileManager.fileExists(atPath: target.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(Self.backupPrefix + formatter.string(from: Date()))
        if fileManager.fileExists(atPath: backup.path) {
            try? fileManager.removeItem(at: backup)
        }
        try fileManager.copyItem(at: target, to: backup)
        pruneBackups(in: target.deletingLastPathComponent())
    }

    private func pruneBackups(in directory: URL) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names.filter { $0.hasPrefix(Self.backupPrefix) }.sorted()
        guard backups.count > Self.keptBackups else { return }
        for name in backups.dropLast(Self.keptBackups) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
