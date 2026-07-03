import AppKit
import Combine

/// Wires together preferences, the file watcher, the session store, the
/// observable model, and the status bar UI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Location of the shared status file the hooks write to.
    private let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudelights-status.json")

    private let preferences = Preferences()
    private let store = SessionStore()
    private let terminalLauncher = TerminalLauncher()
    private let notifications = NotificationManager()
    private let history = SessionHistory()
    private let usage = UsageStats()
    private let updater = Updater()
    private let installer = HookInstaller()
    private let labels = SessionLabels()
    private let concurrency = ConcurrencyStats()
    private lazy var model = AppModel(preferences: preferences)
    private lazy var demo = DemoSessionSimulator(statusURL: statusURL)
    private lazy var onboarding = OnboardingController(model: model)
    private var controller: StatusController?
    private var watcher: FileWatcher?
    private var labelsWatcher: FileWatcher?
    private var cancellables: Set<AnyCancellable> = []

    /// Periodically re-reads the file so stale sessions expire even when no hook
    /// fires (i.e. when the file itself is not changing).
    private var cleanupTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Clicking a session focuses the terminal it runs in (auto-detected).
        model.activateHandler = { [weak self] session in
            self?.terminalLauncher.focus(session: session)
        }

        // Tapping a notification focuses that session's terminal too.
        notifications.onOpenSession = { [weak self] sessionId in
            guard let self,
                  let session = self.store.sessions.first(where: { $0.sessionId == sessionId })
            else { return }
            self.terminalLauncher.focus(session: session)
        }

        // Removing sessions rewrites the status file, then reloads.
        model.removeHandler = { [weak self] session in
            guard let self else { return }
            self.store.remove(sessionId: session.sessionId, from: self.statusURL)
            self.reload()
        }
        model.clearFinishedHandler = { [weak self] in
            guard let self else { return }
            self.store.clearFinished(from: self.statusURL)
            self.reload()
        }

        // Renaming writes the labels file; the single mirror below publishes
        // every change (optimistic set, watcher reloads, failure reverts).
        model.renameHandler = { [weak self] session, label in
            self?.labels.setLabel(label, for: session.sessionId)
        }
        labels.$labels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.model.sessionLabels = $0 }
            .store(in: &cancellables)

        // Software updates (Sparkle). No-op in the swiftc dev build.
        model.canCheckForUpdates = updater.canCheckForUpdates
        model.checkForUpdatesHandler = { [weak self] in
            self?.updater.checkForUpdates()
        }

        // Hook wiring: mirror the installer state into the model and route the
        // install/uninstall/demo/onboarding intents.
        installer.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.model.hookStatus = status }
            .store(in: &cancellables)
        model.installHooksHandler = { [weak self] in try self?.installer.install() }
        model.uninstallHooksHandler = { [weak self] in try self?.installer.uninstall() }
        model.openSettingsFileHandler = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.installer.settingsFileURL)
        }
        model.enableNotificationsHandler = { [weak self] in
            self?.notifications.requestAuthorizationOrOpenSettings()
        }
        model.runDemoHandler = { [weak self] in self?.demo.run() }
        model.showOnboardingHandler = { [weak self] in self?.onboarding.show() }

        // Keep the installed helper in sync with the bundled one (app updates)
        // and detect the current wiring state.
        installer.ensureHelperCurrent()
        installer.refreshStatus()

        controller = StatusController(model: model, history: history, usage: usage, concurrency: concurrency)

        // Show an initial state before any file event arrives.
        reload()

        let watcher = FileWatcher(url: statusURL) { [weak self] in
            // FileWatcher calls back on its own queue; UI work must be on main.
            DispatchQueue.main.async { self?.reload() }
        }
        watcher.start()
        self.watcher = watcher

        // External writers (e.g. a slash-command script) can update labels too.
        let labelsWatcher = FileWatcher(url: labels.fileURL) { [weak self] in
            DispatchQueue.main.async { self?.labels.reload() }
        }
        labelsWatcher.start()
        self.labelsWatcher = labelsWatcher

        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.reload()
            self?.pruneDeadSessions()
        }
        // First liveness scan shortly after launch, so a zombie left behind
        // while the app wasn't running clears after ~1 minute, not ~2 hours
        // (removal still needs a second scan miss).
        pruneDeadSessions()

        // First run: greet the user and offer one-click hook installation.
        // Read the installer state directly (the Combine mirror into the model
        // delivers asynchronously) and defer the notification permission
        // prompt to the onboarding step that explains it — macOS never
        // re-prompts after a denial, so the first ask must not be a surprise.
        let needsOnboarding = !onboarding.hasCompletedOnboarding && installer.status != .installed
        if needsOnboarding {
            onboarding.show()
        } else {
            notifications.requestAuthorization()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        demo.cancel()
        cleanupTimer?.invalidate()
        watcher?.stop()
    }

    /// Scans for sessions whose claude process is gone and removes them after
    /// two consecutive misses. The `ps` call runs off-main; a failed scan
    /// (nil) skips pruning entirely rather than treating everything as dead.
    /// No subprocess is spawned at all while no session carries a tty (the
    /// common idle state).
    private func pruneDeadSessions() {
        guard preferences.removeDeadSessions else { return }
        // pid-carrying sessions are checked directly (no subprocess); the ps
        // scan is only spawned when some session must fall back to its tty.
        let needsTtyScan = store.sessions.contains {
            $0.pid == nil && $0.tty.map(TTYName.isWellFormed) == true
        }
        let hasPidSessions = store.sessions.contains { $0.pid != nil }
        guard needsTtyScan || hasPidSessions else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let liveStarts = needsTtyScan ? ProcessLiveness.liveClaudeStarts() : [:] else { return }
            DispatchQueue.main.async {
                guard let self, self.preferences.removeDeadSessions else { return }
                if self.store.pruneDead(liveStarts: liveStarts, from: self.statusURL) {
                    self.reload()
                }
            }
        }
    }

    /// Reloads the store, pushes sessions into the model, refreshes the icon,
    /// and fires notifications/sound for any state transitions. Main-thread only.
    private func reload() {
        store.reload(from: statusURL)
        model.update(sessions: store.sessions)
        concurrency.sample(count: store.sessions.count)
        controller?.updateIcon()
        handleTransitions(store.recentTransitions)
    }

    /// Coalescing window: rapid consecutive transitions for the same session
    /// only notify once, for the latest state — avoids notification spam when a
    /// session flips state quickly (e.g. working → needs_input → working).
    private let notificationDebounce: TimeInterval = 1.2
    private var pendingNotifications: [String: DispatchWorkItem] = [:]

    /// Records history immediately and schedules a debounced notification/sound
    /// for each session that just changed state.
    private func handleTransitions(_ transitions: [SessionStatus]) {
        for session in transitions {
            // History captures every transition immediately (not debounced),
            // under the same name the panel and notifications show.
            history.record(session, displayName: model.displayName(for: session))
            scheduleNotification(for: session)
        }
    }

    private func scheduleNotification(for session: SessionStatus) {
        // Cancel any pending notification for this session; the latest wins.
        pendingNotifications[session.sessionId]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNotifications[session.sessionId] = nil
            if self.preferences.shouldNotify(for: session.state) {
                self.notifications.notify(
                    session: session,
                    displayName: self.model.displayName(for: session))
            }
            if session.state == .needsInput, self.preferences.soundOnNeedsInput {
                AttentionSound.play(self.preferences.attentionSound)
            }
        }
        pendingNotifications[session.sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notificationDebounce, execute: work)
    }
}
