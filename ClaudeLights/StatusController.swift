import AppKit
import Combine
import SwiftUI

/// Owns the `NSStatusItem` (menu bar icon) and the SwiftUI popover it toggles.
///
/// The icon reflects the worst session state in the user's chosen style
/// (colored dot, emoji, or monochrome template), optionally with a count of
/// sessions needing input; the popover hosts `PanelView` via an
/// `NSHostingController`.
final class StatusController {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let usage: UsageStats
    private let popover: NSPopover
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, history: SessionHistory, usage: UsageStats, concurrency: ConcurrencyStats) {
        self.model = model
        self.usage = usage
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient // Closes when the user clicks elsewhere.
        popover.animates = true

        // Keep the popover sized to the SwiftUI content. Without this the
        // hosting controller reports a stale/default size, which makes the
        // popover mis-anchor and appear offset from the menu bar icon.
        let hosting = NSHostingController(
            rootView: PanelView(model: model, history: history, usage: usage, concurrency: concurrency)
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Re-render when icon preferences change (objectWillChange fires
        // before the new value lands, hence the main-queue hop).
        model.preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &cancellables)

        updateIcon()
    }

    /// Recomputes the menu bar icon from the model's worst state and the
    /// user's icon preferences. Falls back to the "all clear" green icon when
    /// there are no sessions.
    func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = model.worstState ?? .done
        let preferences = model.preferences

        switch preferences.iconStyle {
        case .coloredDot:
            button.image = icon(for: state)
        case .monochrome:
            button.image = monochromeIcon(for: state)
        case .emoji:
            button.image = nil
        }

        // Badge: how many sessions currently need the user.
        let needsInputCount = model.sessions.filter { $0.state == .needsInput }.count
        let badge = (preferences.showNeedsInputCount && needsInputCount > 0) ? " \(needsInputCount)" : ""

        if preferences.iconStyle == .emoji {
            button.attributedTitle = NSAttributedString(
                string: state.emoji + badge,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
            button.imagePosition = .noImage
        } else if !badge.isEmpty {
            button.attributedTitle = NSAttributedString(
                string: badge,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)])
            button.imagePosition = .imageLeft
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }

        button.toolTip = needsInputCount > 0
            ? String(localized: "ClaudeLights — \(needsInputCount) session(s) need input")
            : "ClaudeLights"
    }

    /// Diameter of the menu bar icon, in points.
    private let iconDiameter: CGFloat = 18

    /// Builds the menu bar icon: a filled circle in the state's color with a
    /// white inner glyph, so the state reads by both color and shape. Drawn via
    /// a drawing handler so it stays crisp on Retina. Non-template to keep color.
    private func icon(for state: SessionState) -> NSImage {
        let diameter = iconDiameter
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            state.color.setFill()
            NSBezierPath(ovalIn: rect).fill()

            let configuration = NSImage.SymbolConfiguration(pointSize: diameter * 0.52, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: state.barGlyphName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// Template rendering: the state's bare glyph inside a stroked circle,
    /// tinted by the system like every other menu bar extra. State is conveyed
    /// by shape alone.
    private func monochromeIcon(for state: SessionState) -> NSImage {
        let diameter = iconDiameter
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.75, dy: 0.75)
            let circle = NSBezierPath(ovalIn: inset)
            circle.lineWidth = 1.5
            NSColor.black.setStroke()
            circle.stroke()

            let configuration = NSImage.SymbolConfiguration(pointSize: diameter * 0.48, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
            if let glyph = NSImage(systemSymbolName: state.barGlyphName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh token usage each time the panel opens.
            usage.refresh()
            // Activate first so the accessory app can key the popover window and
            // AppKit anchors it correctly under the status item.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
