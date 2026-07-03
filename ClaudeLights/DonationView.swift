import SwiftUI

/// Content of the donation window: value proof, three anchored amount tiers
/// ($10 emphasized), a custom-amount escape hatch, and — only when the window
/// opened on its own — "Maybe later" / "Don't ask again".
struct DonationView: View {
    let sessionsCompleted: Int
    /// True when the window opened by the auto-show rule rather than the user.
    let isAutoShown: Bool
    let onTier: (URL) -> Void
    let onLater: () -> Void
    let onNever: () -> Void

    @State private var didDonate = false

    var body: some View {
        VStack(spacing: 14) {
            if didDonate {
                thanks
            } else {
                header
                tiers
                footer
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            Text("Enjoying ClaudeLights?")
                .font(.title3).bold()
            Text("ClaudeLights has watched **\(sessionsCompleted) sessions** finish for you. It's free and made by one person — if it saves you time, consider chipping in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tiers: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                tierButton(amount: "$5", url: DonationLinks.tier5, emphasized: false)
                tierButton(amount: "$10", url: DonationLinks.tier10, emphasized: true)
                tierButton(amount: "$25", url: DonationLinks.tier25, emphasized: false)
            }
            Button { donate(DonationLinks.custom) } label: {
                Text("Custom amount…").font(.caption)
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func tierButton(amount: LocalizedStringKey, url: URL, emphasized: Bool) -> some View {
        VStack(spacing: 3) {
            // Reserve the badge line on every tier so the buttons align.
            Text(emphasized ? "Popular" : " ")
                .font(.caption2).bold()
                .foregroundStyle(.tint)
            if emphasized {
                Button { donate(url) } label: {
                    Text(amount).font(.headline).frame(width: 70)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button { donate(url) } label: {
                    Text(amount).frame(width: 60)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isAutoShown {
            HStack {
                Button { onLater() } label: {
                    Text("Maybe later").font(.caption)
                }
                .buttonStyle(.link)
                Spacer()
                Button { onNever() } label: {
                    Text("Don't ask again")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var thanks: some View {
        VStack(spacing: 8) {
            Text("Thank you! ♥")
                .font(.title3).bold()
            Text("Your support keeps ClaudeLights going.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button { onLater() } label: {
                Text("Close")
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 8)
    }

    private func donate(_ url: URL) {
        onTier(url)
        withAnimation { didDonate = true }
    }
}
