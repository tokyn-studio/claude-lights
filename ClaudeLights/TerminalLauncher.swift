import AppKit

/// Brings the terminal/editor a session runs in to the front when the user
/// clicks it, walking a tiered chain of `FocusStrategy` implementations from
/// most precise (exact tmux/WezTerm/kitty pane, exact Terminal/iTerm tab) to
/// least (activating the hosting app). See FocusStrategies.swift.
///
/// Focusing Terminal/iTerm windows uses Apple events, so macOS asks the user
/// to grant Automation permission the first time
/// (see `NSAppleEventsUsageDescription`).
final class TerminalLauncher {
    /// Subprocess-based strategies must not block the UI; the chain runs on
    /// this queue and individual strategies hop to main where required.
    private let queue = DispatchQueue(label: "studio.tokyn.claudelights.focus", qos: .userInitiated)

    /// One focus attempt at a time: a hung terminal can hold the chain for
    /// several subprocess timeouts, and impatient re-clicks must be dropped
    /// rather than queue up behind it.
    private let inFlight = NSLock()
    private var isFocusing = false

    private let strategies: [FocusStrategy] = [
        TmuxFocusStrategy(),
        WezTermFocusStrategy(),
        KittyFocusStrategy(),
        AppleScriptTtyFocusStrategy(),
        EditorSessionFocusStrategy(),   // exact terminal tab via companion extension
        WorkspaceFolderFocusStrategy(), // exact + permissionless: must precede AX
        WindowTitleFocusStrategy(),
        AppActivationFallbackStrategy(),
    ]

    /// Focuses the session, preferring its exact pane/window.
    func focus(session: SessionStatus) {
        inFlight.lock()
        let busy = isFocusing
        if !busy { isFocusing = true }
        inFlight.unlock()
        if busy {
            NSLog("ClaudeLights: focus already in progress, ignoring click")
            return
        }

        queue.async { [strategies] in
            defer {
                self.inFlight.lock()
                self.isFocusing = false
                self.inFlight.unlock()
            }
            for strategy in strategies {
                if strategy.attempt(session) {
                    NSLog("ClaudeLights: focused \(session.shortSessionId) via \(type(of: strategy))")
                    return
                }
            }
            NSLog("ClaudeLights: no focus strategy could handle session \(session.shortSessionId)")
        }
    }
}
