import AppKit
import Foundation
import UserNotifications

/// macOS notifications and the Dock badge.
///
/// Scope note: a Mac app that is not running cannot receive anything. kvidr follows
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
    /// Set by the app so a reminder's click can show the message it is about.
    var onOpenMessage: ((String, Int) -> Void)?
    /// Set by the app: whether the user's own status is Do Not Disturb right now.
    var isDoNotDisturb: () -> Bool = { false }

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
        guard conversation.shouldNotify(forMention: isMention, isDoNotDisturb: isDoNotDisturb()) else { return }

        let content = UNMutableNotificationContent()
        content.title = conversation.displayName

        // A sensitive conversation says who and where, never what — whatever the preference.
        if let message = conversation.lastMessage, preferences.showsNotificationPreviews, !conversation.isSensitive {
            let preview = MessageContentParser(currentUserID: "", markdownEnabled: false)
                .parse(message)
                .preview
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

    // MARK: - Reminders

    private static let reminderPrefix = "reminder-"
    private var reminderScheduling: Task<Void, Never>?

    /// Replaces every scheduled reminder notification with these. macOS delivers them at
    /// their time whether or not kvidr is running.
    func scheduleReminders(_ reminders: [Reminder], conversation: @escaping (String) -> Conversation?) {
        let requests = reminders.filter { $0.date > Date() }.map { reminder in
            let room = conversation(reminder.token)
            let content = UNMutableNotificationContent()
            content.title = room.map { "Reminder: \($0.displayName)" } ?? "Reminder"
            let sender = reminder.actor.resolvedDisplayName
            if preferences.showsNotificationPreviews, room?.isSensitive != true, !reminder.text.isEmpty {
                let preview = MessageContentParser(currentUserID: "", markdownEnabled: false)
                    .parse(Message(messageID: reminder.messageID, token: reminder.token, actor: reminder.actor,
                                   timestamp: reminder.date, text: reminder.text, parameters: reminder.parameters))
                    .preview
                content.subtitle = sender
                content.body = preview
            } else {
                content.body = sender.isEmpty ? "A message you asked to be reminded about" : "A message from \(sender)"
            }
            if preferences.playsNotificationSound { content.sound = .default }
            content.userInfo = ["token": reminder.token, "messageID": reminder.messageID]
            content.threadIdentifier = reminder.token
            content.interruptionLevel = .timeSensitive

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
            return UNNotificationRequest(
                identifier: Self.reminderPrefix + reminder.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
        }

        // One replacement at a time: two overlapping ones could each clear the pending list
        // before either added to it, and leave both sets scheduled.
        let previous = reminderScheduling
        let center = self.center
        reminderScheduling = Task {
            await previous?.value
            let pending = await center.pendingNotificationRequests()
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for request in requests {
                do {
                    try await center.add(request)
                } catch {
                    Log.notification.warning("Couldn’t schedule reminder: \(error.localizedDescription)")
                }
            }
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
        let userInfo = response.notification.request.content.userInfo
        let token = userInfo["token"] as? String
        let messageID = userInfo["messageID"] as? Int
        await MainActor.run { [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard let token else { return }
            if let messageID, let open = self?.onOpenMessage {
                open(token, messageID)
            } else {
                self?.onOpenConversation?(token)
            }
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
