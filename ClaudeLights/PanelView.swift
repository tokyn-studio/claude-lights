import SwiftUI

/// Which content the popover currently shows.
private enum PanelMode {
    case sessions
    case usage
    case history
    case settings
}

/// The popover shown when the menu bar icon is clicked: active sessions, usage
/// stats, a transition history, and settings. Driven entirely by `AppModel` /
/// `SessionHistory` / `UsageStats`.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: SessionHistory
    @ObservedObject var usage: UsageStats
    @State private var mode: PanelMode = .sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: - Header / navigation

    private var header: some View {
        HStack(spacing: 10) {
            Text(headerTitle)
                .font(.headline)
            Spacer()
            if mode == .sessions {
                Button { mode = .usage } label: { Image(systemName: "chart.bar") }
                    .buttonStyle(.plain)
                    .help(Text("Usage"))
                Button { mode = .history } label: { Image(systemName: "clock") }
                    .buttonStyle(.plain)
                    .help(Text("History"))
                Button { mode = .settings } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help(Text("Settings"))
            } else {
                Button { mode = .sessions } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help(Text("Back"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerTitle: LocalizedStringKey {
        switch mode {
        case .sessions: return "ClaudeLights"
        case .usage: return "Usage"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .sessions: sessionSection
        case .usage: UsageView(usage: usage, history: history)
        case .history: HistoryView(history: history)
        case .settings: SettingsView(model: model, preferences: model.preferences)
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionSection: some View {
        if model.sessions.isEmpty {
            Text("No active sessions")
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
        } else {
            VStack(spacing: 0) {
                ForEach(model.sessions, id: \.sessionId) { session in
                    SessionRow(
                        session: session,
                        displayName: model.displayName(for: session),
                        customLabel: model.sessionLabels[session.sessionId],
                        onTap: { model.activate(session) },
                        onRemove: { model.remove(session) },
                        onRename: { model.rename(session, to: $0) }
                    )
                }
                if model.hasFinishedSessions {
                    Divider().padding(.vertical, 2)
                    Button { model.clearFinished() } label: {
                        Text("Clear finished")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Button { model.quit() } label: {
            Text("Quit")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A single, clickable session row with a hover-revealed remove button and
/// context-menu renaming (inline text field; Enter commits, Esc cancels,
/// an empty name restores the project default).
private struct SessionRow: View {
    let session: SessionStatus
    let displayName: String
    let customLabel: String?
    let onTap: () -> Void
    let onRemove: () -> Void
    let onRename: (String?) -> Void
    @State private var hovering = false
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var nameFieldFocused: Bool

    private var isIdle: Bool { session.isIdle() }

    private var dotColor: Color {
        Color(nsColor: isIdle ? SessionState.idleColor : session.state.color)
    }

    private var symbolName: String {
        isIdle ? SessionState.idleSymbolName : session.state.symbolName
    }

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                editingContent
            } else {
                Button(action: onTap) {
                    rowContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Tooltip shows the full (possibly truncated) name plus the action.
                .help(Text(verbatim: displayName))
                .contextMenu {
                    Button { beginEditing() } label: { Text("Rename…") }
                    if customLabel != nil {
                        Button { onRename(nil) } label: { Text("Clear name") }
                    }
                    Button(role: .destructive, action: onRemove) { Text("Remove") }
                }

                // Remove button, shown on hover to keep the row clean.
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Remove"))
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onHover { hovering = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(dotColor)
                .font(.system(size: 12))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text(isIdle ? LocalizedStringKey("Idle") : stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            timeView
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var editingContent: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(dotColor)
                .font(.system(size: 12))
                .frame(width: 14)
            TextField(session.displayName, text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($nameFieldFocused)
                .onSubmit { commitEditing() }
                .onExitCommand { cancelEditing() }
                // Finder-style commit on blur: clicking elsewhere must not
                // leave the row stuck as an unfocusable text field.
                .onChange(of: nameFieldFocused) { focused in
                    if !focused { commitEditing() }
                }
        }
    }

    private func beginEditing() {
        draft = customLabel ?? ""
        isEditing = true
        focusNameField()
    }

    /// The context menu's teardown can still hold first responder for a
    /// moment, dropping a single focus request — retry briefly.
    private func focusNameField(attempt: Int = 0) {
        guard isEditing, attempt < 5 else { return }
        nameFieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if isEditing && !nameFieldFocused {
                focusNameField(attempt: attempt + 1)
            }
        }
    }

    private func commitEditing() {
        guard isEditing else { return }
        isEditing = false
        onRename(draft)
    }

    private func cancelEditing() {
        // Clear the flag before focus moves so the blur handler won't commit.
        isEditing = false
    }

    private var stateLabel: LocalizedStringKey { stateDisplayLabel(session.state) }

    /// Formats seconds as a stopwatch string ("0:05", "5:23", "1:02:03") to match
    /// the live `.timer` style exactly.
    private static func stopwatch(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// While actively working: a live stopwatch of accumulated active time
    /// (pauses during needs_input). While paused/done: the frozen total. Falls
    /// back to relative time for entries that predate the timing fields.
    @ViewBuilder
    private var timeView: some View {
        if let reference = session.timerReference {
            Text(reference, style: .timer)
        } else if let worked = session.frozenWorked {
            Text(Self.stopwatch(worked))
        } else {
            Text(session.timestamp, style: .relative)
        }
    }
}

/// The transition history list.
private struct HistoryView: View {
    @ObservedObject var history: SessionHistory

    var body: some View {
        if history.entries.isEmpty {
            Text("No history yet")
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(history.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.state.symbolName)
                                .foregroundStyle(Color(nsColor: entry.state.color))
                                .font(.system(size: 10))
                                .frame(width: 12)
                            Text(entry.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .help(Text(verbatim: entry.displayName))
                            Spacer()
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
        }
    }
}

/// Localized label for a session state, shared across rows and stats.
private func stateDisplayLabel(_ state: SessionState) -> LocalizedStringKey {
    switch state {
    case .working: return "Working"
    case .compacting: return "Compacting"
    case .done: return "Done"
    case .needsInput: return "Needs input"
    }
}

/// Today's token usage and time-per-state analytics.
private struct UsageView: View {
    @ObservedObject var usage: UsageStats
    let history: SessionHistory

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Display order: most attention-worthy first.
    private let orderedStates: [SessionState] = [.needsInput, .working, .compacting, .done]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Today's tokens").font(.subheadline).bold()
                tokenRow("Input", usage.today.input)
                tokenRow("Output", usage.today.output)
                tokenRow("Cache read", usage.today.cacheRead)
                tokenRow("Cache write", usage.today.cacheCreation)
                Divider()
                tokenRow("Total", usage.today.total)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Time per state").font(.subheadline).bold()
                let times = history.timePerStateToday()
                let visible = orderedStates.filter { (times[$0] ?? 0) > 0 }
                if visible.isEmpty {
                    Text("No activity yet today")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(visible, id: \.self) { state in
                        HStack(spacing: 6) {
                            Image(systemName: state.symbolName)
                                .foregroundStyle(Color(nsColor: state.color))
                                .font(.system(size: 10))
                                .frame(width: 12)
                            Text(stateDisplayLabel(state)).font(.caption)
                            Spacer()
                            Text(durationText(times[state] ?? 0))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func tokenRow(_ label: LocalizedStringKey, _ value: Int) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(value.formatted()).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        if interval < 60 { return String(localized: "< 1 min") }
        return Self.durationFormatter.string(from: interval) ?? ""
    }
}

/// Settings shown inside the popover (notifications, general).
private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code Hooks")
                .font(.subheadline).bold()
            hooksSection

            Divider().padding(.vertical, 4)

            Text("Menu bar")
                .font(.subheadline).bold()
            HStack(spacing: 6) {
                Text("Icon style").font(.caption)
                Picker("Icon style", selection: $preferences.iconStyle) {
                    Text("Colored dot").tag(MenuIconStyle.coloredDot)
                    Text("Emoji").tag(MenuIconStyle.emoji)
                    Text("Monochrome").tag(MenuIconStyle.monochrome)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Toggle(isOn: $preferences.showNeedsInputCount) {
                Text("Show count of sessions needing input")
            }

            Divider().padding(.vertical, 4)

            Text("Notifications")
                .font(.subheadline).bold()
            Toggle(isOn: $preferences.notifyNeedsInput) { Text("When a session needs input") }
            Toggle(isOn: $preferences.notifyWorking) { Text("When a session starts working") }
            Toggle(isOn: $preferences.notifyDone) { Text("When a session is done") }
            Toggle(isOn: $preferences.soundOnNeedsInput) { Text("Play sound on needs input") }

            // Sound picker + preview, enabled only when the sound is on.
            HStack(spacing: 6) {
                Text("Sound").font(.caption)
                Picker("Sound", selection: $preferences.attentionSound) {
                    ForEach(AttentionSound.all, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button {
                    AttentionSound.play(preferences.attentionSound)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .help(Text("Preview"))
            }
            .controlSize(.small)
            .padding(.leading, 18)
            .disabled(!preferences.soundOnNeedsInput)
            .opacity(preferences.soundOnNeedsInput ? 1 : 0.5)

            Divider().padding(.vertical, 4)

            Text("General")
                .font(.subheadline).bold()
            Toggle(isOn: Binding(
                get: { model.startsAtLogin },
                set: { _ in model.toggleStartAtLogin() }
            )) {
                Text("Start at Login")
            }
            Toggle(isOn: $preferences.removeDeadSessions) {
                Text("Remove sessions whose process died")
            }
            if model.canCheckForUpdates {
                Button { model.checkForUpdates() } label: {
                    Text("Check for Updates…")
                }
                .buttonStyle(.link)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Hook wiring status with the matching action (install/repair/migrate/
    /// uninstall) and a way back into the welcome window.
    @ViewBuilder
    private var hooksSection: some View {
        switch model.hookStatus {
        case .installed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Installed").font(.caption)
                Spacer()
                Button { model.uninstallHooks() } label: {
                    Text("Uninstall…").font(.caption)
                }
                .buttonStyle(.link)
            }
        case .settingsUnreadable:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.json could not be parsed").font(.caption)
                }
                Button { model.openSettingsFile() } label: {
                    Text("Open settings.json").font(.caption)
                }
                .buttonStyle(.link)
            }
        case .legacyShellHooks:
            hookActionRow(label: "Legacy shell hooks found", action: "Migrate")
        case .needsRepair:
            hookActionRow(label: "Needs repair", action: "Repair")
        case .notInstalled, .unknown:
            hookActionRow(label: "Not installed", action: "Install")
        }

        if let error = model.lastHookActionError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        Button { model.showOnboarding() } label: {
            Text("Show welcome window").font(.caption)
        }
        .buttonStyle(.link)
    }

    private func hookActionRow(label: LocalizedStringKey, action: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
            Text(label).font(.caption)
            Spacer()
            Button { model.installHooks() } label: {
                Text(action).font(.caption)
            }
            .controlSize(.small)
        }
    }
}
