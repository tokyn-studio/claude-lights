import Foundation

// Headless fixture tests for HookInstaller.
// Usage: installertest <path-to-built-claudelights-hook>

let helperBinary = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

func makeSandbox() -> (settings: URL, helperDir: URL, dir: URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clinst-\(UUID().uuidString)")
    try! fm.createDirectory(at: dir.appendingPathComponent("claude"), withIntermediateDirectories: true)
    return (dir.appendingPathComponent("claude/settings.json"),
            dir.appendingPathComponent("helpers"), dir)
}

func makeInstaller(_ sandbox: (settings: URL, helperDir: URL, dir: URL), settings: URL? = nil) -> HookInstaller {
    HookInstaller(settingsURL: settings ?? sandbox.settings,
                  helperDirectory: sandbox.helperDir,
                  bundledHelperURL: helperBinary)
}

func json(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

func commands(in settings: [String: Any]) -> [String] {
    var result: [String] = []
    for (_, value) in settings["hooks"] as? [String: Any] ?? [:] {
        for group in value as? [[String: Any]] ?? [] {
            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                if let command = hook["command"] as? String { result.append(command) }
            }
        }
    }
    return result
}

// --- 1: install onto a missing settings.json ---------------------------------
do {
    let sandbox = makeSandbox()
    let installer = makeInstaller(sandbox)
    installer.refreshStatus()
    check("missing file -> notInstalled", installer.status == .notInstalled)
    try installer.install()
    check("install -> installed", installer.status == .installed)
    let events = (json(sandbox.settings)["hooks"] as? [String: Any])?.keys.sorted() ?? []
    check("all six events wired", events == ["Notification", "PostToolUse", "PreCompact", "SessionEnd", "Stop", "UserPromptSubmit"], "\(events)")
    check("helper copied", fm.isExecutableFile(atPath: sandbox.helperDir.appendingPathComponent("claudelights-hook").path))
    let notification = ((json(sandbox.settings)["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])?.first
    check("notification matcher preserved", notification?["matcher"] as? String == "idle_prompt|permission_prompt")
}

// --- 2: idempotence -----------------------------------------------------------
do {
    let sandbox = makeSandbox()
    let installer = makeInstaller(sandbox)
    try installer.install()
    let first = try Data(contentsOf: sandbox.settings)
    try installer.install()
    let second = try Data(contentsOf: sandbox.settings)
    check("double install identical", first == second)
}

// --- 3: foreign hooks and settings survive ------------------------------------
do {
    let sandbox = makeSandbox()
    let existing = """
    {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/my-notify.sh"}]}],
     "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/guard.sh"}]}]}}
    """
    try existing.data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    try installer.install()
    let result = json(sandbox.settings)
    let cmds = commands(in: result)
    check("foreign Stop hook survives", cmds.contains("/usr/local/bin/my-notify.sh"))
    check("foreign PreToolUse hook survives", cmds.contains("/usr/local/bin/guard.sh"))
    check("top-level setting survives", result["model"] as? String == "opus")
    check("our Stop hook added", cmds.contains { $0.contains("claudelights-hook' done") })
    try installer.uninstall()
    let after = json(sandbox.settings)
    let cmdsAfter = commands(in: after)
    check("uninstall keeps foreign hooks", cmdsAfter.sorted() == ["/usr/local/bin/guard.sh", "/usr/local/bin/my-notify.sh"], "\(cmdsAfter)")
    check("uninstall -> notInstalled", installer.status == .notInstalled)
}

// --- 4: legacy shell hooks are detected and migrated ---------------------------
do {
    let sandbox = makeSandbox()
    let legacy = """
    {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "'/Users/x/claude-lights/hooks/working.sh'"}]}],
     "Stop": [{"hooks": [{"type": "command", "command": "'/Users/x/claude-lights/hooks/done.sh'"}]}]}}
    """
    try legacy.data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    installer.refreshStatus()
    check("legacy detected", installer.status == .legacyShellHooks)
    try installer.install()
    let cmds = commands(in: json(sandbox.settings))
    check("legacy entries removed", !cmds.contains { $0.contains("hooks/working.sh") })
    check("migrated to installed", installer.status == .installed)
}

// --- 5: unreadable settings are never written ----------------------------------
do {
    let sandbox = makeSandbox()
    let broken = "// my settings\n{ \"hooks\": {} }"  // JSONC comment: unparseable
    try broken.data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    installer.refreshStatus()
    var unreadable = false
    if case .settingsUnreadable = installer.status { unreadable = true }
    check("commented JSON -> settingsUnreadable", unreadable)
    var threw = false
    do { try installer.install() } catch { threw = true }
    let content = String(data: try Data(contentsOf: sandbox.settings), encoding: .utf8)
    check("install refuses to write", threw && content == broken)

    // Trailing commas parse on modern Foundation: install proceeds and
    // normalizes the file instead of refusing (a backup is taken anyway).
    let sandbox2 = makeSandbox()
    try "{ \"hooks\": { \"Stop\": [], } }".data(using: .utf8)!.write(to: sandbox2.settings)
    let installer2 = makeInstaller(sandbox2)
    try installer2.install()
    check("trailing comma tolerated + normalized", installer2.status == .installed)
}

// --- 6: symlinked settings.json keeps the link ----------------------------------
do {
    let sandbox = makeSandbox()
    let real = sandbox.dir.appendingPathComponent("dotfiles-settings.json")
    try "{}".data(using: .utf8)!.write(to: real)
    try fm.createSymbolicLink(at: sandbox.settings, withDestinationURL: real)
    let installer = makeInstaller(sandbox)
    try installer.install()
    let isStillLink = (try? fm.destinationOfSymbolicLink(atPath: sandbox.settings.path)) != nil
    check("symlink preserved", isStillLink)
    check("target updated through link", !commands(in: json(real)).isEmpty)
}

// --- 7: repair detection (wrong path + outdated helper) --------------------------
do {
    let sandbox = makeSandbox()
    let wrongPath = """
    {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "'/old/place/claudelights-hook' working"}]}]}}
    """
    try wrongPath.data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    installer.refreshStatus()
    check("old path -> needsRepair(wrongPath)", installer.status == .needsRepair(.wrongPath))
    try installer.install()
    check("repair install -> installed", installer.status == .installed)

    // Corrupt the installed helper: SHA mismatch must be detected and healed.
    try "stale".data(using: .utf8)!.write(to: sandbox.helperDir.appendingPathComponent("claudelights-hook"))
    installer.refreshStatus()
    check("stale helper -> needsRepair(helperOutdated)", installer.status == .needsRepair(.helperOutdated))
    installer.ensureHelperCurrent()
    installer.refreshStatus()
    check("ensureHelperCurrent heals", installer.status == .installed)
}

// --- 8: backups created and pruned to 3 -------------------------------------------
do {
    let sandbox = makeSandbox()
    try "{}".data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    for _ in 0..<5 {
        try installer.install()
        Thread.sleep(forTimeInterval: 1.1)  // backup names have second granularity
    }
    let backups = try fm.contentsOfDirectory(atPath: sandbox.settings.deletingLastPathComponent().path)
        .filter { $0.hasPrefix("settings.json.claudelights-backup-") }
    check("backups pruned to 3", backups.count == 3, "\(backups.count)")
}

// --- 9: unrecognized foreign shapes are preserved verbatim ---------------------
do {
    let sandbox = makeSandbox()
    let weird = """
    {"hooks": {"Stop": [{"hooks": "run-me-somehow"}, {"note": "no hooks key"}],
     "SessionStart": []}}
    """
    try weird.data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    try installer.install()
    var result = json(sandbox.settings)
    var stop = (result["hooks"] as? [String: Any])?["Stop"] as? [Any] ?? []
    check("weird-shaped foreign groups survive install",
          stop.contains { ($0 as? [String: Any])?["hooks"] as? String == "run-me-somehow" }
          && stop.contains { ($0 as? [String: Any])?["note"] as? String == "no hooks key" },
          "\(stop)")
    try installer.uninstall()
    result = json(sandbox.settings)
    stop = (result["hooks"] as? [String: Any])?["Stop"] as? [Any] ?? []
    check("weird-shaped foreign groups survive uninstall", stop.count == 2, "\(stop)")
    let sessionStart = (result["hooks"] as? [String: Any])?["SessionStart"] as? [Any]
    check("foreign empty event array survives uninstall", sessionStart != nil)
}

// --- 10: legacy hooks in a renamed directory are still migrated ----------------
do {
    let sandbox = makeSandbox()
    let legacy = """
    {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "'/Users/x/Downloads/claude-lights-main/hooks/done.sh'"}]}]}}
    """
    try legacy.data(using: .utf8)!.write(to: sandbox.settings)
    let installer = makeInstaller(sandbox)
    installer.refreshStatus()
    check("renamed-dir legacy detected", installer.status == .legacyShellHooks)
    try installer.install()
    let cmds = commands(in: json(sandbox.settings))
    check("renamed-dir legacy removed", !cmds.contains { $0.contains("hooks/done.sh") })
}

// --- 11: restrictive settings.json permissions survive the rewrite -------------
do {
    let sandbox = makeSandbox()
    try "{}".data(using: .utf8)!.write(to: sandbox.settings)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sandbox.settings.path)
    let installer = makeInstaller(sandbox)
    try installer.install()
    let mode = (try fm.attributesOfItem(atPath: sandbox.settings.path)[.posixPermissions] as? NSNumber)?.intValue
    check("chmod 600 preserved", mode == 0o600, String(mode ?? -1, radix: 8))
}

// --- 12: helper path with a single quote produces a shell-parseable command ----
do {
    let sandbox = makeSandbox()
    let quotedDir = sandbox.dir.appendingPathComponent("o'brien helpers")
    let installer = HookInstaller(settingsURL: sandbox.settings,
                                  helperDirectory: quotedDir,
                                  bundledHelperURL: helperBinary)
    try installer.install()
    let cmds = commands(in: json(sandbox.settings))
    check("guard + no-op form", cmds.allSatisfy { $0.hasPrefix("[ -x ") && $0.hasSuffix("|| true") })
    var parseable = true
    for command in cmds {
        let script = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmd-\(UUID().uuidString).sh")
        try command.data(using: .utf8)!.write(to: script)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-n", script.path]
        try sh.run()
        sh.waitUntilExit()
        if sh.terminationStatus != 0 { parseable = false }
    }
    check("apostrophe path shell-parseable", parseable, "\(cmds.first ?? "")")
}

print(failures == 0 ? "\nAll installer fixture tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
