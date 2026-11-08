import AppKit
import os
import ReviewQueueCore
import UserNotifications

/// Posts queue alerts and opens the PR, or its Linear review, when one is clicked. Every alert is posted silent
/// because `AlertSound` plays its sound.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private static let githubAction = "github"
    private static let linearAction = "linear"
    private static let githubCategory = "pr-github"
    private static let bothCategory = "pr-both"
    private static let log = Logger(subsystem: AppIdentity.bundleId, category: "notifications")

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let github = UNNotificationAction(identifier: Self.githubAction, title: "GitHub Review")
        let linear = UNNotificationAction(identifier: Self.linearAction, title: "Linear Review")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.githubCategory, actions: [github], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.bothCategory, actions: [github, linear], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { isGranted, error in
            if let error {
                Self.log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.notice("authorization granted: \(isGranted, privacy: .public)")
            }
        }
    }

    /// What macOS currently allows, for the Settings status line: "Allowed", "Denied" and so on.
    func permission() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: "Allowed"
        case .provisional: "Allowed quietly"
        case .denied: "Denied in System Settings"
        case .notDetermined: "Not asked yet"
        case .ephemeral: "Allowed temporarily"
        @unknown default: "Unknown"
        }
    }

    func post(_ alerts: [PrAlert]) {
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.subtitle = alert.subtitle
            content.body = alert.body
            content.userInfo = ["url": alert.url, "linearUrl": alert.linearUrl ?? ""]
            content.categoryIdentifier = alert.linearUrl == nil ? Self.githubCategory : Self.bothCategory
            let identifier = alert.kind == .high ? "high-\(alert.id)" : "\(alert.id)-\(UUID().uuidString)"
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if let error {
                    Self.log.error("post \(identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    Self.log.notice("posted \(identifier, privacy: .public)")
                }
            }
        }
    }

    /// Clears a PR's delivered High priority notification once it is marked done.
    func withdraw(_ key: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["high-\(key)"])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let key = response.actionIdentifier == Self.linearAction ? "linearUrl" : "url"
        guard let link = info[key] as? String, let url = URL(string: link), !link.isEmpty else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
