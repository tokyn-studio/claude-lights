import SwiftUI

/// First-run welcome window: explains the traffic light, installs the Claude
/// Code hooks with one click, offers the notification permission, and lets the
/// user watch a simulated session cycle through the states.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            trafficLightLegend
            Divider()
            installStep
            notificationStep
            demoStep
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to ClaudeLights")
                .font(.title2).bold()
            Text("A traffic light for your Claude Code sessions, right in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trafficLightLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: .green, text: "Green — done, waiting for your next prompt")
            legendRow(color: .yellow, text: "Yellow — Claude is working")
            legendRow(color: .red, text: "Red — Claude needs your input")
        }
    }

    private func legendRow(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 1: hooks

    @ViewBuilder
    private var installStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepTitle(number: 1, title: "Connect to Claude Code")
            Text("ClaudeLights adds a few hook entries to ~/.claude/settings.json so Claude Code reports its status. A backup of the file is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.hookStatus {
            case .installed:
                Label {
                    Text("Hooks installed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
                Text("Restart any running Claude Code sessions so they pick up the hooks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .settingsUnreadable(let detail):
                Label {
                    Text("settings.json could not be parsed: \(detail)")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                Button { model.openSettingsFile() } label: { Text("Open settings.json") }
            default:
                Button { model.installHooks() } label: {
                    Text(installButtonTitle)
                }
                .keyboardShortcut(.defaultAction)
            }

            if let error = model.lastHookActionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var installButtonTitle: LocalizedStringKey {
        switch model.hookStatus {
        case .legacyShellHooks: return "Migrate Hooks"
        case .needsRepair: return "Repair Hooks"
        default: return "Install Hooks"
        }
    }

    // MARK: - Step 2: notifications

    private var notificationStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepTitle(number: 2, title: "Get notified")
            Text("Allow notifications so ClaudeLights can tell you when a session needs your input — even when you're in another app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.enableNotifications() } label: {
                Text("Enable Notifications")
            }
            Text("Clicking a session later triggers a one-time macOS prompt to allow controlling your terminal.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 3: demo

    private var demoStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepTitle(number: 3, title: "See it in action")
            Text("Run a simulated session: watch the menu bar icon turn yellow, red, then green.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.runDemo() } label: {
                Text("Simulate a Demo Session")
            }
        }
    }

    private func stepTitle(number: Int, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
        }
    }

    private var footer: some View {
        HStack {
            Text("Reopen this window anytime from Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { onDone() } label: {
                Text("Done")
            }
        }
    }
}
