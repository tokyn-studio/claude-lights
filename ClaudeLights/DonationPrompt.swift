import Foundation

/// Stripe Payment Link destinations for the donation tiers.
///
/// Paste the real links from the Stripe dashboard (fixed $5/$10/$25 plus one
/// "customer chooses price" link with a $2 minimum). While the slugs still
/// say REPLACE, `isConfigured` is false and every donation entry point in the
/// app (welcome line, panel button, auto-prompt) stays hidden.
enum DonationLinks {
    static let tier5 = URL(string: "https://buy.stripe.com/REPLACE_TIER_5")!
    static let tier10 = URL(string: "https://buy.stripe.com/REPLACE_TIER_10")!
    static let tier25 = URL(string: "https://buy.stripe.com/REPLACE_TIER_25")!
    static let custom = URL(string: "https://buy.stripe.com/REPLACE_CUSTOM")!

    static var isConfigured: Bool {
        !tier5.absoluteString.contains("REPLACE")
    }
}

/// Everything the donation prompt needs to remember between launches.
struct DonationState: Equatable {
    /// Transitions into `.done` observed so far, across all sessions.
    var completedSessions = 0
    /// How often the window auto-opened (hard-capped by the rule).
    var autoShowCount = 0
    /// `completedSessions` at the moment of the last auto-show.
    var lastShownAtCount = 0
    /// User clicked "Don't ask again".
    var dismissedForever = false
    /// User clicked a donation tier (optimistic — there is no backend to
    /// verify the payment, and a nag after a real donation is worse than
    /// staying quiet after an abandoned checkout).
    var donated = false
}

/// Pure decision logic for when the donation window may open on its own.
///
/// The ask is deliberately late (after the user has seen real value) and
/// rare: first at 25 completed sessions, at most one reminder 50 sessions
/// after a "Maybe later", never after "Don't ask again" or a donation.
enum DonationPromptRule {
    static let firstAskThreshold = 25
    static let reAskDelta = 50
    static let maxAutoShows = 2

    static func shouldAutoShow(state: DonationState) -> Bool {
        if state.dismissedForever || state.donated { return false }
        if state.autoShowCount >= maxAutoShows { return false }
        if state.autoShowCount == 0 {
            return state.completedSessions >= firstAskThreshold
        }
        return state.completedSessions >= state.lastShownAtCount + reAskDelta
    }
}

/// Persists `DonationState` in `UserDefaults`.
final class DonationStateStore {
    private let defaults: UserDefaults

    private enum Key {
        static let completedSessions = "donationCompletedSessions"
        static let autoShowCount = "donationAutoShowCount"
        static let lastShownAtCount = "donationLastShownAtCount"
        static let dismissedForever = "donationDismissedForever"
        static let donated = "donationDonated"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: DonationState {
        DonationState(
            completedSessions: defaults.integer(forKey: Key.completedSessions),
            autoShowCount: defaults.integer(forKey: Key.autoShowCount),
            lastShownAtCount: defaults.integer(forKey: Key.lastShownAtCount),
            dismissedForever: defaults.bool(forKey: Key.dismissedForever),
            donated: defaults.bool(forKey: Key.donated)
        )
    }

    func update(_ change: (inout DonationState) -> Void) {
        var next = state
        change(&next)
        defaults.set(next.completedSessions, forKey: Key.completedSessions)
        defaults.set(next.autoShowCount, forKey: Key.autoShowCount)
        defaults.set(next.lastShownAtCount, forKey: Key.lastShownAtCount)
        defaults.set(next.dismissedForever, forKey: Key.dismissedForever)
        defaults.set(next.donated, forKey: Key.donated)
    }
}
