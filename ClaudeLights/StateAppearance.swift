import AppKit

/// Visual mapping from a session state to its traffic-light color. Kept separate
/// from `Models.swift` so the model layer stays free of AppKit.
extension SessionState {
    /// The menu bar / dot color for this state.
    var color: NSColor {
        switch self {
        case .done: return .systemGreen
        case .compacting: return .systemBlue
        case .working: return .systemYellow
        case .needsInput: return .systemRed
        }
    }

    /// The dimmed color used for an idle (long-done) session.
    static var idleColor: NSColor { .systemGray }

    /// A distinct filled-circle SF Symbol per state (used in the panel lists), so
    /// the state is conveyed by shape as well as color (not color alone).
    var symbolName: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .working: return "ellipsis.circle.fill"
        case .compacting: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsInput: return "exclamationmark.circle.fill"
        }
    }

    /// The bare inner glyph (no enclosing circle), composited in white over a
    /// colored circle for the menu bar icon.
    var barGlyphName: String {
        switch self {
        case .done: return "checkmark"
        case .working: return "ellipsis"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .needsInput: return "exclamationmark"
        }
    }

    /// SF Symbol shown for a session that is idle (long done).
    static var idleSymbolName: String { "moon.zzz.fill" }

    /// Emoji rendering of the state for the emoji menu bar style.
    var emoji: String {
        switch self {
        case .done: return "🟢"
        case .working: return "🟡"
        case .compacting: return "🔵"
        case .needsInput: return "🔴"
        }
    }

    /// Human-readable label used for accessibility descriptions.
    var accessibilityLabel: String {
        switch self {
        case .done: return "Done"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .needsInput: return "Needs input"
        }
    }
}
