import AppKit
import UserNotifications

/// Delivers desktop notifications for session state transitions and plays the
/// optional attention sound. Tapping a notification calls `onOpenSession`.
///
/// Notifications require a properly bundled (and, for reliable delivery,
/// signed/notarized) app. The code is defensive so an unauthorized or
/// unavailable notification center never crashes the app.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// Invoked with the session id when the user clicks a delivered notification.
    var onOpenSession: ((String) -> Void)?

    /// Requests notification permission and registers as delegate. Safe to call
    /// once at launch.
    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("ClaudeLights: notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    /// Requests permission — or, if the user previously denied it, opens the
    /// System Settings notifications pane instead, because macOS never shows
    /// the permission dialog a second time.
    func requestAuthorizationOrOpenSettings() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .denied {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    self?.requestAuthorization()
                }
            }
        }
    }

    /// Posts a notification describing a session's new state.
    func notify(session: SessionStatus) {
        let content = UNMutableNotificationContent()
        content.title = title(for: session.state)
        content.body = session.displayName
        content.userInfo = ["sessionId": session.sessionId]
        // Sound is handled separately (see playAttentionSound) so it can be
        // toggled independently of banners.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "\(session.sessionId)-\(session.state.rawValue)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("ClaudeLights: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    private func title(for state: SessionState) -> String {
        switch state {
        case .working:
            return String(localized: "Claude Code is working")
        case .compacting:
            return String(localized: "Claude Code is compacting context")
        case .done:
            return String(localized: "Claude Code is done")
        case .needsInput:
            return String(localized: "Claude Code needs your input")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while ClaudeLights is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Tapping a notification focuses the terminal of the originating session.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionId = response.notification.request.content.userInfo["sessionId"] as? String {
            onOpenSession?(sessionId)
        }
        completionHandler()
    }
}
