import Foundation

// Headless logic tests for the focus-strategy chain: field validation,
// binary resolution, and subprocess handling. Strategies that need a real
// terminal (tmux/kitty/WezTerm/AppleScript) are exercised only on their
// fall-through paths here; the happy paths need a manual pass per terminal.

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

func session(
    term: String? = nil, tty: String? = nil, cwd: String? = nil,
    bundleId: String? = nil, tmuxPane: String? = nil, weztermPane: String? = nil,
    kittyWindowId: String? = nil, kittyListenOn: String? = nil
) -> SessionStatus {
    SessionStatus(
        state: .working, sessionId: "test-1", project: "proj", term: term,
        tty: tty, started: nil, activeSeconds: nil, timestamp: Date(),
        cwd: cwd, bundleId: bundleId, tmuxPane: tmuxPane,
        weztermPane: weztermPane, kittyWindowId: kittyWindowId,
        kittyListenOn: kittyListenOn)
}

// --- FocusSupport.run ---------------------------------------------------------
check("run captures stdout", FocusSupport.run("/bin/echo", ["hello"])?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
check("run nil on non-zero exit", FocusSupport.run("/usr/bin/false", []) == nil)
check("run nil on missing binary", FocusSupport.run("/no/such/binary", []) == nil)
let start = Date()
check("run kills on timeout", FocusSupport.run("/bin/sleep", ["5"], timeout: 0.4) == nil)
check("timeout is enforced (<2s)", Date().timeIntervalSince(start) < 2)

// --- FocusSupport.resolveBinary -------------------------------------------------
check("resolveBinary finds system binaries", FocusSupport.resolveBinary(named: "true") == "/usr/bin/true")
check("resolveBinary nil for unknown", FocusSupport.resolveBinary(named: "definitely-not-a-binary-xyz") == nil)
check("resolveBinary prefers extra candidates",
      FocusSupport.resolveBinary(named: "true", extraCandidates: ["/bin/ls"]) == "/bin/ls")

// --- hostBundleId + allowlist ------------------------------------------------------
check("bundleId wins over term map",
      FocusSupport.hostBundleId(of: session(term: "vscode", bundleId: "com.jetbrains.intellij")) == "com.jetbrains.intellij")
check("term map used without bundleId",
      FocusSupport.hostBundleId(of: session(term: "zed")) == "dev.zed.Zed")
check("nil for unknown host", FocusSupport.hostBundleId(of: session(term: "mystery")) == nil)
check("arbitrary bundleId rejected, term map wins",
      FocusSupport.hostBundleId(of: session(term: "vscode", bundleId: "com.apple.Calculator")) == "com.microsoft.VSCode")
check("arbitrary bundleId alone -> nil",
      FocusSupport.hostBundleId(of: session(bundleId: "com.evil.launcher")) == nil)
check("allowlist accepts terminals", FocusSupport.isAllowedHost("com.mitchellh.ghostty"))
check("allowlist accepts JetBrains prefix", FocusSupport.isAllowedHost("com.jetbrains.pycharm.ce"))
check("allowlist accepts Xcode", FocusSupport.isAllowedHost("com.apple.dt.Xcode"))
check("allowlist accepts VS Code forks", FocusSupport.isAllowedHost("com.google.antigravity")
      && FocusSupport.isAllowedHost("com.exafunction.windsurf"))
check("allowlist rejects others", !FocusSupport.isAllowedHost("com.apple.Safari"))

// --- titleMatchCandidates ------------------------------------------------------
let home = NSHomeDirectory()
check("candidates deepest first, home filtered",
      FocusSupport.titleMatchCandidates(forCwd: "\(home)/projects/frontend/src") == ["src", "frontend", "projects"])
check("short components filtered",
      FocusSupport.titleMatchCandidates(forCwd: "/tmp/ab/x") == ["tmp"])
check("home itself yields nothing", FocusSupport.titleMatchCandidates(forCwd: home).isEmpty)
check("candidates capped at 4",
      FocusSupport.titleMatchCandidates(forCwd: "/aaa/bbb/ccc/ddd/eee/fff").count == 4)

// --- strategy fall-through on invalid/missing fields --------------------------------
check("tmux: no pane -> false", !TmuxFocusStrategy().attempt(session(term: "tmux")))
check("tmux: malformed pane -> false", !TmuxFocusStrategy().attempt(session(tmuxPane: "%5; rm -rf /")))
check("wezterm: malformed pane -> false", !WezTermFocusStrategy().attempt(session(weztermPane: "7 --oops")))
check("kitty: injection listen_on -> false",
      !KittyFocusStrategy().attempt(session(kittyWindowId: "3", kittyListenOn: "unix:/tmp/k;$(reboot)")))
check("kitty: no listen_on -> false", !KittyFocusStrategy().attempt(session(kittyWindowId: "3")))
check("applescript: wrong term -> false",
      !AppleScriptTtyFocusStrategy().attempt(session(term: "ghostty", tty: "ttys001")))
check("applescript: no tty -> false",
      !AppleScriptTtyFocusStrategy().attempt(session(term: "Apple_Terminal")))
check("workspace: missing cwd on disk -> false",
      !WorkspaceFolderFocusStrategy().attempt(session(term: "vscode", cwd: "/no/such/dir")))
check("workspace: wrong term -> false",
      !WorkspaceFolderFocusStrategy().attempt(session(term: "Apple_Terminal", cwd: "/tmp")))
check("workspace: editor not running -> false",
      !WorkspaceFolderFocusStrategy().attempt(session(term: "zed", cwd: "/tmp")))
check("fallback: unknown host -> false", !AppActivationFallbackStrategy().attempt(session(term: "mystery")))
check("fallback: spoofed bundleId not activated",
      !AppActivationFallbackStrategy().attempt(session(bundleId: "com.apple.Calculator")))
// Window-title strategy: only paths that bail before the Accessibility trust
// check (a headless test run must never trigger the system prompt).
check("windowtitle: unknown host -> false",
      !WindowTitleFocusStrategy().attempt(session(term: "mystery", cwd: "/tmp/projects/x")))
check("windowtitle: app not running -> false",
      !WindowTitleFocusStrategy().attempt(session(term: "zed", cwd: "/tmp/projects/x")))
check("windowtitle: no cwd -> false",
      !WindowTitleFocusStrategy().attempt(session(term: "zed")))

print(failures == 0 ? "\nAll focus logic tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
