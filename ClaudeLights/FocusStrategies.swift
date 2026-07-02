import AppKit

/// One way of bringing a session's terminal/editor to the front.
///
/// Strategies are tried in order (see `TerminalLauncher`); the first one that
/// reports success wins. Tiers, from most to least precise:
///   1. exact pane/tab   — tmux, WezTerm, kitty, Terminal.app, iTerm2
///   2. exact window     — VS Code / Cursor / Zed via their workspace folder
///   3. app activation   — everything else, using the captured bundle id
protocol FocusStrategy {
    /// Attempts to focus the session. Returns false to fall through to the
    /// next strategy. Called on a background queue; implementations that need
    /// the main thread (AppleScript, NSWorkspace) hop over synchronously.
    func attempt(_ session: SessionStatus) -> Bool
}

/// Shared plumbing for the strategies: terminal registry, app activation,
/// subprocess execution, and the AppleScript window targeting.
enum FocusSupport {
    /// Maps a `TERM_PROGRAM` value to the terminal app's bundle identifier.
    static let bundleIdByTerm: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "zed": "dev.zed.Zed",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "Hyper": "co.zeit.hyper",
        "Tabby": "org.tabby",
        "kitty": "net.kovidgoyal.kitty",
        "Alacritty": "org.alacritty",
    ]

    /// Additional hosts we accept from the captured `__CFBundleIdentifier`:
    /// IDEs with embedded terminals that set no TERM_PROGRAM, plus VS Code
    /// forks that report `TERM_PROGRAM=vscode` under their own bundle id.
    private static let allowedHostBundleIds: Set<String> = [
        "com.apple.dt.Xcode",
        "com.google.android.studio",
        "com.google.antigravity",
        "com.exafunction.windsurf",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.vscodium.VSCodiumInsiders",
    ]

    /// The status file is world-writable, so `bundle_id` is attacker-
    /// controlled input: only terminals/IDEs we know may ever be activated
    /// (the pre-engine code had the same allowlist property via its
    /// TERM_PROGRAM map — activating arbitrary apps must stay impossible).
    static func isAllowedHost(_ bundleId: String) -> Bool {
        bundleIdByTerm.values.contains(bundleId)
            || allowedHostBundleIds.contains(bundleId)
            || bundleId.hasPrefix("com.jetbrains.")
    }

    /// The bundle id of the app hosting a session: the captured
    /// `__CFBundleIdentifier` when it names a known terminal/IDE (works for
    /// JetBrains and other apps that set no TERM_PROGRAM), else the
    /// TERM_PROGRAM mapping.
    static func hostBundleId(of session: SessionStatus) -> String? {
        if let captured = session.bundleId, isAllowedHost(captured) {
            return captured
        }
        return session.term.flatMap { bundleIdByTerm[$0] }
    }

    /// Activates an app by bundle identifier, launching it if necessary.
    /// Returns false when the app is not installed.
    @discardableResult
    static func activate(bundleId: String) -> Bool {
        var activated = false
        runOnMain {
            let workspace = NSWorkspace.shared
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
                NSLog("ClaudeLights: app not installed: \(bundleId)")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: url, configuration: configuration, completionHandler: nil)
            activated = true
        }
        return activated
    }

    static func isRunning(bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Runs a binary with an argument array (never through a shell). Returns
    /// stdout on exit 0, nil on launch failure, non-zero exit, or timeout —
    /// the timeout keeps a hung tmux server from freezing the focus click.
    /// stderr is discarded; a chatty child must never fill a pipe we forgot
    /// to drain. On timeout the child gets SIGTERM, then SIGKILL, so neither
    /// the process nor the stdout drain thread can leak.
    static func run(_ executablePath: String, _ arguments: [String], timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        // Drain stdout concurrently so a chatty process can't fill the pipe
        // and deadlock against our wait. The buffer is lock-protected: on a
        // drain timeout we must not read it while the reader might still write.
        let lock = NSLock()
        var buffer = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            buffer = data
            lock.unlock()
            drained.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate() // SIGTERM, then escalate:
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            return nil
        }
        // A forked grandchild can inherit the pipe's write end and keep it
        // open past the parent's exit; don't wait forever, and don't touch
        // the buffer unless the reader is done with it.
        guard drained.wait(timeout: .now() + 0.5) == .success else { return nil }

        guard process.terminationStatus == 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8)
    }

    /// Finds a CLI binary in the usual install locations (Homebrew on Apple
    /// silicon and Intel, system) plus strategy-specific candidates.
    static func resolveBinary(named name: String, extraCandidates: [String] = []) -> String? {
        let candidates = extraCandidates + [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - AppleScript tty targeting (Terminal.app, iTerm2)

    /// Focuses the Terminal.app/iTerm2 window whose tab/session sits on `tty`.
    /// Returns whether a matching window was found. Only queries apps that are
    /// already running (a `tell application` would otherwise launch them), and
    /// only activates on a match. The tty is validated to prevent script
    /// injection (it originates from the on-disk status file, which any local
    /// process can write).
    static func focusWindow(bundleId: String, tty: String) -> Bool {
        guard tty.range(of: "^ttys?[0-9]+$", options: .regularExpression) != nil,
              isRunning(bundleId: bundleId)
        else { return false }
        let source: String
        switch bundleId {
        case "com.apple.Terminal": source = terminalScript(tty: tty)
        case "com.googlecode.iterm2": source = itermScript(tty: tty)
        default: return false
        }

        // NSAppleScript is main-thread-only.
        var found = false
        runOnMain {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                NSLog("ClaudeLights: AppleScript focus failed: \(error)")
                return
            }
            found = result.stringValue == "1"
        }
        return found
    }

    static func runOnMain(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }

    // MARK: - Accessibility window targeting (IDEs and other terminals)

    /// Whether ClaudeLights may drive other apps' windows via the
    /// Accessibility API. The first time an IDE session actually needs it,
    /// the system permission dialog is shown (once per launch); until the
    /// user grants access the caller falls through to app activation.
    private static var promptedForAccessibility = false
    static func ensureAccessibilityTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !promptedForAccessibility {
            promptedForAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    /// Title fragments to look for in window titles, derived from the
    /// session's working directory: its path components, deepest first, so
    /// `/Users/me/projects/frontend/src` prefers a window named after `src`,
    /// then `frontend`. Components of the home directory path and very short
    /// names are skipped — they'd match half the screen.
    static func titleMatchCandidates(forCwd cwd: String) -> [String] {
        let homeComponents = Set(URL(fileURLWithPath: NSHomeDirectory()).pathComponents)
        let candidates = URL(fileURLWithPath: cwd).pathComponents
            .reversed()
            .filter { $0 != "/" && $0.count >= 3 && !homeComponents.contains($0) }
        return Array(candidates.prefix(4))
    }

    /// Raises the app window whose title mentions one of `candidates`.
    /// Returns false when no window matches (or accessibility is denied).
    static func raiseWindow(pid: pid_t, matching candidates: [String]) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], !windows.isEmpty
        else { return false }

        var titles: [(window: AXUIElement, title: String)] = []
        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String, !title.isEmpty
            else { continue }
            titles.append((window, title))
        }

        for candidate in candidates {
            for (window, title) in titles where title.range(of: candidate, options: .caseInsensitive) != nil {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                return true
            }
        }
        return false
    }

    /// AppleScript to focus the Terminal.app tab whose tty ends with `tty`.
    /// Activates only on a match, so probing never fronts (or launches) the app.
    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) ends with "\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        activate
                        return "1"
                    end if
                end repeat
            end repeat
        end tell
        return "0"
        """
    }

    /// AppleScript to focus the iTerm2 session whose tty ends with `tty`.
    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) ends with "\(tty)" then
                            select w
                            select t
                            activate
                            return "1"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "0"
        """
    }
}

// MARK: - Tier 1: exact pane

/// tmux: selects the session's window and pane, then brings the terminal
/// hosting the attached tmux client to the front. Works no matter which
/// terminal tmux runs in; fixes the pre-engine behavior where
/// `TERM_PROGRAM=tmux` focused nothing at all.
struct TmuxFocusStrategy: FocusStrategy {
    func attempt(_ session: SessionStatus) -> Bool {
        guard let pane = session.tmuxPane,
              pane.range(of: "^%[0-9]+$", options: .regularExpression) != nil,
              let tmux = FocusSupport.resolveBinary(named: "tmux")
        else { return false }

        // The pane must still exist, and we need its tmux session name.
        guard let panes = FocusSupport.run(tmux, ["list-panes", "-a", "-F", "#{pane_id}\t#{session_name}"]),
              let paneLine = panes.split(separator: "\n").first(where: { $0.hasPrefix("\(pane)\t") }),
              let tmuxSession = paneLine.split(separator: "\t", maxSplits: 1).last.map(String.init)
        else { return false }

        guard FocusSupport.run(tmux, ["select-window", "-t", pane]) != nil,
              FocusSupport.run(tmux, ["select-pane", "-t", pane]) != nil
        else { return false }

        // Bring an attached client over to this tmux session if needed, and
        // remember its outer tty so we can focus the hosting terminal window.
        var clientTTY: String?
        if let clients = FocusSupport.run(tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}"]) {
            let rows = clients.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1) }
            if let attached = rows.first(where: { $0.count == 2 && String($0[1]) == tmuxSession }) {
                clientTTY = String(attached[0])
            } else if let other = rows.first, other.count == 2 {
                clientTTY = String(other[0])
                _ = FocusSupport.run(tmux, ["switch-client", "-c", clientTTY!, "-t", tmuxSession])
            }
        }

        // No attached client: the pane is selected, but there is no window to
        // surface. Fall through so a later strategy can at least front an app.
        guard let clientTTY else { return false }

        // Find the terminal window showing the ATTACHED client. The captured
        // bundle_id reflects whichever app started the tmux *server*, which
        // may long since have changed — so match the client tty against both
        // tty-scriptable terminals (running apps only) before trusting it.
        let outerTTY = clientTTY.replacingOccurrences(of: "/dev/", with: "")
        let sessionHost = FocusSupport.hostBundleId(of: session)
        var candidates = ["com.googlecode.iterm2", "com.apple.Terminal"]
        if let sessionHost, candidates.contains(sessionHost) {
            candidates.removeAll { $0 == sessionHost }
            candidates.insert(sessionHost, at: 0)
        }
        for candidate in candidates where FocusSupport.focusWindow(bundleId: candidate, tty: outerTTY) {
            return true
        }

        // Client is attached inside a non-scriptable terminal: activate the
        // captured host app (allowlisted) as the best remaining guess.
        if let sessionHost, FocusSupport.activate(bundleId: sessionHost) { return true }
        return false
    }
}

/// WezTerm: activates the exact pane via `wezterm cli`, then the app.
struct WezTermFocusStrategy: FocusStrategy {
    func attempt(_ session: SessionStatus) -> Bool {
        guard let pane = session.weztermPane,
              pane.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              let wezterm = FocusSupport.resolveBinary(
                named: "wezterm",
                extraCandidates: ["/Applications/WezTerm.app/Contents/MacOS/wezterm"])
        else { return false }

        guard FocusSupport.run(wezterm, ["cli", "activate-pane", "--pane-id", pane]) != nil else {
            return false
        }
        FocusSupport.activate(bundleId: FocusSupport.bundleIdByTerm["WezTerm"]!)
        return true
    }
}

/// kitty: focuses the exact OS window via kitty's remote control. Requires
/// `allow_remote_control` in the user's kitty.conf; otherwise the command
/// fails and the chain falls through to app activation.
struct KittyFocusStrategy: FocusStrategy {
    func attempt(_ session: SessionStatus) -> Bool {
        guard let windowId = session.kittyWindowId,
              windowId.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              let listenOn = session.kittyListenOn,
              listenOn.range(of: "^(unix:|tcp:)[A-Za-z0-9_@%/.:-]+$", options: .regularExpression) != nil,
              let kitty = FocusSupport.resolveBinary(
                named: "kitty",
                extraCandidates: ["/Applications/kitty.app/Contents/MacOS/kitty"])
        else { return false }

        guard FocusSupport.run(kitty, ["@", "--to", listenOn, "focus-window", "--match", "id:\(windowId)"]) != nil else {
            return false
        }
        FocusSupport.activate(bundleId: FocusSupport.bundleIdByTerm["kitty"]!)
        return true
    }
}

/// Terminal.app / iTerm2: focuses the exact tab/session via AppleScript,
/// matched by the session's tty.
struct AppleScriptTtyFocusStrategy: FocusStrategy {
    func attempt(_ session: SessionStatus) -> Bool {
        guard let term = session.term,
              let bundleId = FocusSupport.bundleIdByTerm[term],
              bundleId == "com.apple.Terminal" || bundleId == "com.googlecode.iterm2",
              let tty = session.tty, !tty.isEmpty
        else { return false }
        return FocusSupport.focusWindow(bundleId: bundleId, tty: tty)
    }
}

// MARK: - Tier 2: exact window

/// Any running host app (JetBrains, Xcode, Antigravity and other VS Code
/// forks, Ghostty, Warp, …): find the window whose title mentions the
/// session's directory and raise it via the Accessibility API.
///
/// IDE and terminal window titles almost always contain the project folder
/// name, so matching the cwd's path components (deepest first) picks the
/// right window without any per-app scripting support. Needs the one-time
/// Accessibility permission; until granted, the chain falls through to app
/// activation.
struct WindowTitleFocusStrategy: FocusStrategy {
    func attempt(_ session: SessionStatus) -> Bool {
        guard let bundleId = FocusSupport.hostBundleId(of: session),
              let cwd = session.cwd,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        else { return false }

        let candidates = FocusSupport.titleMatchCandidates(forCwd: cwd)
        guard !candidates.isEmpty,
              FocusSupport.ensureAccessibilityTrusted(),
              FocusSupport.raiseWindow(pid: app.processIdentifier, matching: candidates)
        else { return false }

        FocusSupport.runOnMain { app.activate(options: []) }
        return true
    }
}

/// VS Code / Cursor / Zed: re-opening the session's working directory focuses
/// the window that already has that folder open.
///
/// Only runs while the editor is running — a cold launch or a project the
/// user deliberately closed should not be reopened just to focus something
/// (the fallback strategy then simply activates the app). Known limitation:
/// if the folder itself isn't open (the window has a parent folder or a
/// multi-root workspace), the editor opens a new window for it.
struct WorkspaceFolderFocusStrategy: FocusStrategy {
    private static let terms: Set<String> = ["vscode", "cursor", "zed"]

    func attempt(_ session: SessionStatus) -> Bool {
        // hostBundleId (not the term map): VS Code forks like Antigravity or
        // Windsurf report TERM_PROGRAM=vscode but must open the folder in
        // their own app, identified by the captured bundle id.
        guard let term = session.term, Self.terms.contains(term),
              let bundleId = FocusSupport.hostBundleId(of: session),
              FocusSupport.isRunning(bundleId: bundleId),
              let cwd = session.cwd,
              FileManager.default.fileExists(atPath: cwd)
        else { return false }

        var opened = false
        FocusSupport.runOnMain {
            let workspace = NSWorkspace.shared
            guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // Fire and forget: waiting on the completion handler would race a
            // cold editor and let the chain double-activate on a late reply.
            workspace.open([URL(fileURLWithPath: cwd, isDirectory: true)],
                           withApplicationAt: appURL,
                           configuration: configuration,
                           completionHandler: nil)
            opened = true
        }
        return opened
    }
}

// MARK: - Tier 3: app activation

/// Last resort: bring the hosting app to the front. Uses the captured bundle
/// id (allowlisted), so JetBrains IDEs — which set no TERM_PROGRAM — land in
/// the right app.
struct AppActivationFallbackStrategy: FocusStrategy {
    func attempt(_ session: SessionStatus) -> Bool {
        guard let bundleId = FocusSupport.hostBundleId(of: session) else {
            if let term = session.term {
                NSLog("ClaudeLights: unknown terminal '\(term)', cannot focus")
            }
            return false
        }
        return FocusSupport.activate(bundleId: bundleId)
    }
}
