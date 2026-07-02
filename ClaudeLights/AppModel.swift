import AppKit

/// The single observable source of truth for the SwiftUI popover.
///
/// `AppDelegate` pushes fresh sessions into it after every file reload; the UI
/// observes `sessions` and the intent methods route user actions back out
/// through injectable handlers (wired up as later phases add behavior).
final class AppModel: ObservableObject {
    /// Sessions to display, already sorted (worst state first) by the store.
    @Published private(set) var sessions: [SessionStatus] = []

    /// Mirrors the current login-item registration for the settings toggle.
    @Published var startsAtLogin: Bool

    let preferences: Preferences
    private let loginItem = LoginItem()

    /// Invoked when the user clicks a session (wired to the terminal launcher).
    var activateHandler: ((SessionStatus) -> Void)?
    /// Invoked when the user removes a single session.
    var removeHandler: ((SessionStatus) -> Void)?
    /// Invoked when the user clears all finished sessions.
    var clearFinishedHandler: (() -> Void)?
    /// Invoked when the user asks to check for updates.
    var checkForUpdatesHandler: (() -> Void)?

    /// Whether the "Check for Updates…" control should be shown (Sparkle linked).
    @Published var canCheckForUpdates = false

    /// Current state of the Claude Code hook wiring, mirrored from the installer.
    @Published var hookStatus: HookInstallStatus = .unknown
    /// The last install/uninstall failure, shown inline in onboarding/settings.
    @Published var lastHookActionError: String?

    /// Invoked to install (or repair/migrate) the hook wiring.
    var installHooksHandler: (() throws -> Void)?
    /// Invoked to remove our hook entries from settings.json.
    var uninstallHooksHandler: (() throws -> Void)?
    /// Invoked to reveal settings.json (when it cannot be parsed).
    var openSettingsFileHandler: (() -> Void)?
    /// Invoked to (re-)request notification permission.
    var enableNotificationsHandler: (() -> Void)?
    /// Invoked to run the simulated demo session.
    var runDemoHandler: (() -> Void)?
    /// Invoked to reopen the welcome window.
    var showOnboardingHandler: (() -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        self.startsAtLogin = loginItem.isEnabled
    }

    /// The highest-severity state across all sessions, or `nil` if none.
    var worstState: SessionState? {
        sessions.map(\.state).max { $0.severity < $1.severity }
    }

    /// Replaces the visible sessions (called on the main thread after a reload).
    func update(sessions: [SessionStatus]) {
        self.sessions = sessions
    }

    // MARK: - Intents

    func activate(_ session: SessionStatus) {
        activateHandler?(session)
    }

    func remove(_ session: SessionStatus) {
        removeHandler?(session)
    }

    func clearFinished() {
        clearFinishedHandler?()
    }

    func checkForUpdates() {
        checkForUpdatesHandler?()
    }

    func installHooks() {
        do {
            try installHooksHandler?()
            lastHookActionError = nil
        } catch {
            lastHookActionError = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            try uninstallHooksHandler?()
            lastHookActionError = nil
        } catch {
            lastHookActionError = error.localizedDescription
        }
    }

    func openSettingsFile() {
        openSettingsFileHandler?()
    }

    func enableNotifications() {
        enableNotificationsHandler?()
    }

    func runDemo() {
        runDemoHandler?()
    }

    func showOnboarding() {
        showOnboardingHandler?()
    }

    /// True when at least one session is finished (enables "Clear finished").
    var hasFinishedSessions: Bool {
        sessions.contains { $0.state == .done }
    }

    func toggleStartAtLogin() {
        loginItem.toggle()
        startsAtLogin = loginItem.isEnabled
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
