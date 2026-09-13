import AppKit
import Foundation
import UserNotifications

/// macOS notifications and the Dock badge.
///
/// Scope note: a Mac app that is not running cannot receive anything. Talk for Mac follows
/// the ordinary macOS messaging-app model — it keeps running after its last window closes
/// and syncs while running. What real push would require is written up in
/// docs/NEXTCLOUD_API.md § 10; there is no fake push architecture here.
@MainActor
final class NotificationController: NSObject {
    private let preferences: Preferences
    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false

    /// Set by the app so a click can change the selection.
    var onOpenConversation: ((String) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.notification.warning("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    /// Raises a notification for a conversation with new activity, if the user's settings
    /// and the conversation's own notification level allow it.
    func notifyIfNeeded(about conversation: Conversation) {
        guard preferences.showsNotifications else { return }

        let isMention = conversation.unreadMention || conversation.unreadMentionDirect
        // The server-side notification level is the user's choice; we respect it rather
        // than inventing our own policy.
        guard conversation.shouldNotify(forMention: isMention) else { return }

        let content = UNMutableNotificationContent()
        content.title = conversation.displayName

        if let message = conversation.lastMessage, preferences.showsNotificationPreviews {
            let parser = MessageContentParser(currentUserID: "", markdownEnabled: false)
            let preview = parser.parse(message).preview
            if conversation.isOneToOne || message.isSystem {
                content.body = preview
            } else {
                content.subtitle = message.actor.resolvedDisplayName
                content.body = preview
            }
        } else {
            content.body = isMention ? "Mentioned you" : "New message"
        }

        if preferences.playsNotificationSound { content.sound = .default }
        content.userInfo = ["token": conversation.token]
        content.threadIdentifier = conversation.token
        if isMention { content.interruptionLevel = .timeSensitive }

        let request = UNNotificationRequest(
            identifier: "\(conversation.token)-\(conversation.lastActivity.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { Log.notification.warning("Couldn’t post notification: \(error.localizedDescription)") }
        }
    }

    /// Dock badge. Cleared entirely when the preference is off, so it can't get stuck.
    func updateBadge(count: Int) {
        let label = preferences.showsDockBadge && count > 0 ? String(count) : nil
        NSApplication.shared.dockTile.badgeLabel = label
    }

    /// Removes delivered notifications for a conversation the user has now read.
    func clearNotifications(for token: String) {
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { $0.request.content.threadIdentifier == token }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    /// Clicking a notification opens that conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let token = response.notification.request.content.userInfo["token"] as? String
        await MainActor.run { [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let token { self?.onOpenConversation?(token) }
        }
    }

    /// Show banners even while the app is frontmost — but only for conversations the user
    /// isn't currently looking at; that filtering happens before we ever post one.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
