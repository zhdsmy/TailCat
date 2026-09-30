import Foundation
import TailCatCore
@preconcurrency import UserNotifications

/// Thin wrapper so RuleManager / runners can request alerts without importing UserNotifications
/// into TailCatCore (which stays UI-free for unit tests).
@MainActor
enum AppNotifications {
    /// userInfo key holding a file path to reveal in Finder when the notification is clicked.
    nonisolated static let revealKey = "reveal"

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(title: String, body: String, reveal: URL? = nil) {
        guard AppSettings().notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let reveal { content.userInfo = [revealKey: reveal.path] }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
