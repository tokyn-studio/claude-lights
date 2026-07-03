import Foundation

// Headless tests for the donation prompt: the pure auto-show rule
// (thresholds, re-ask window, show cap, opt-outs) and the UserDefaults
// round-trip of DonationStateStore.

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name) \(detail)")
        failures += 1
    }
}

// --- DonationPromptRule.shouldAutoShow --------------------------------------------

func state(
    completed: Int = 0, shows: Int = 0, lastAt: Int = 0,
    never: Bool = false, donated: Bool = false
) -> DonationState {
    DonationState(
        completedSessions: completed, autoShowCount: shows,
        lastShownAtCount: lastAt, dismissedForever: never, donated: donated)
}

check("fresh install", !DonationPromptRule.shouldAutoShow(state: state()))
check("just below first threshold",
      !DonationPromptRule.shouldAutoShow(state: state(completed: 24)))
check("at first threshold",
      DonationPromptRule.shouldAutoShow(state: state(completed: 25)))
check("well past first threshold, never shown",
      DonationPromptRule.shouldAutoShow(state: state(completed: 400)))

// After the first show at 25, the re-ask needs 50 more completions.
check("shown once, too soon to re-ask",
      !DonationPromptRule.shouldAutoShow(state: state(completed: 74, shows: 1, lastAt: 25)))
check("shown once, re-ask window reached",
      DonationPromptRule.shouldAutoShow(state: state(completed: 75, shows: 1, lastAt: 25)))

// Hard cap: never more than two auto-shows.
check("shown twice, never again",
      !DonationPromptRule.shouldAutoShow(state: state(completed: 10_000, shows: 2, lastAt: 75)))

// Opt-outs beat everything.
check("dismissed forever",
      !DonationPromptRule.shouldAutoShow(state: state(completed: 10_000, never: true)))
check("already donated",
      !DonationPromptRule.shouldAutoShow(state: state(completed: 10_000, donated: true)))
check("donated beats pending re-ask",
      !DonationPromptRule.shouldAutoShow(state: state(completed: 75, shows: 1, lastAt: 25, donated: true)))

// --- DonationStateStore round-trip ------------------------------------------------

let suite = "claudelights-donation-tests"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)

let store = DonationStateStore(defaults: defaults)
check("store starts empty", store.state == DonationState())

store.update { $0.completedSessions += 3 }
store.update { $0.completedSessions += 2 }
check("completions accumulate", store.state.completedSessions == 5)

store.update { s in
    s.autoShowCount += 1
    s.lastShownAtCount = s.completedSessions
}
check("show recorded", store.state.autoShowCount == 1 && store.state.lastShownAtCount == 5)

store.update { $0.donated = true }
store.update { $0.dismissedForever = true }
let reread = DonationStateStore(defaults: UserDefaults(suiteName: suite)!)
check("flags persist across store instances",
      reread.state.donated && reread.state.dismissedForever)

defaults.removePersistentDomain(forName: suite)

// --- links guard --------------------------------------------------------------------

check("placeholder links are not configured", !DonationLinks.isConfigured)

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All donation tests passed.")
