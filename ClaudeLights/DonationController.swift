import AppKit
import SwiftUI

/// Owns the donation window and its persisted state. The window opens on its
/// own at most twice (see `DonationPromptRule`) and stays reachable forever
/// via the panel footer and the welcome screen.
final class DonationController {
    private let store: DonationStateStore
    private var window: NSWindow?

    /// Fires after the user clicks a donation tier, so the UI can switch its
    /// labels to the thank-you variant.
    var onDonated: (() -> Void)?

    init(store: DonationStateStore = DonationStateStore()) {
        self.store = store
    }

    var hasDonated: Bool { store.state.donated }

    /// Counts sessions finishing (transitions into `.done`) toward the
    /// auto-show threshold and the "N sessions" line in the window.
    func recordCompletions(_ transitions: [SessionStatus]) {
        let finished = transitions.filter { $0.state == .done }.count
        guard finished > 0 else { return }
        store.update { $0.completedSessions += finished }
    }

    /// Called once per launch; opens the window when the rule allows it.
    func autoShowIfEligible() {
        guard DonationLinks.isConfigured,
              DonationPromptRule.shouldAutoShow(state: store.state) else { return }
        store.update { state in
            state.autoShowCount += 1
            state.lastShownAtCount = state.completedSessions
        }
        show(auto: true)
    }

    func show(auto: Bool = false) {
        // Rebuild each time so the session count and footer context are fresh.
        window?.close()

        let view = DonationView(
            sessionsCompleted: store.state.completedSessions,
            isAutoShown: auto,
            onTier: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.store.update { $0.donated = true }
                self?.onDonated?()
            },
            onLater: { [weak self] in self?.window?.close() },
            onNever: { [weak self] in
                self?.store.update { $0.dismissedForever = true }
                self?.window?.close()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Support ClaudeLights")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
