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
    /// Set by the app: someone calling was answered or declined from their notification.
    var onAnswerCall: ((String) -> Void)?
    var onDeclineCall: ((String) -> Void)?
    /// Set by the app: whether the user's own status is Do Not Disturb right now.
    var isDoNotDisturb: () -> Bool = { false }

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.callCategory,
                actions: [UNNotificationAction(identifier: Self.joinAction, title: String(localized: "Join in Browser", comment: "Notification button: join the call in the web browser"), options: [.foreground])],
                intentIdentifiers: [],
                options: []
            ),
            // One action, so macOS shows it as a button rather than folding two into an
            // Options menu; the notification's own close button declines.
            UNNotificationCategory(
                identifier: Self.incomingCallCategory,
                actions: [UNNotificationAction(identifier: Self.answerAction, title: String(localized: "Answer", comment: "Notification button: answer an incoming call"), options: [.foreground])],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
        ])
    }

    nonisolated private static let callCategory = "call"
    nonisolated private static let joinAction = "join"
    nonisolated private static let incomingCallCategory = "incoming-call"
    nonisolated private static let answerAction = "answer"
    private static let incomingPrefix = "incoming-"
    private static let callPrefix = "call-"

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
            content.body = isMention
                ? String(localized: "Mentioned you", comment: "Notification body when the message's text is hidden: someone @-mentioned you")
                : String(localized: "New message", comment: "Notification body when the message's text is hidden")
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

    // MARK: - Calls

    /// Someone is calling, or a call started. The server has already worded it ("Bob wants to
    /// talk with you"); the banner offers the way in, since kvidr can't join a call itself.
    func announceCall(_ notification: ServerNotification, in conversation: Conversation?, isDoNotDisturb: Bool) {
        guard preferences.showsNotifications else { return }
        if let conversation {
            guard conversation.notificationCalls != 0 else { return }
            if isDoNotDisturb && !conversation.isImportant { return }
        }

        let content = UNMutableNotificationContent()
        content.title = conversation?.displayName ?? String(localized: "notification.call.title", defaultValue: "Call", comment: "Notification title for a call in an unknown conversation (noun)")
        content.body = notification.subject.isEmpty ? String(localized: "A call is waiting for you") : notification.subject
        content.categoryIdentifier = Self.callCategory
        content.interruptionLevel = .timeSensitive
        if preferences.playsNotificationSound { content.sound = .default }
        var info: [String: Any] = [:]
        if case .call(let token) = notification.kind { info["token"] = token }
        if let link = notification.link { info["link"] = link.absoluteString }
        content.userInfo = info

        let request = UNNotificationRequest(identifier: Self.callPrefix + String(notification.id), content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.notification.warning("Couldn’t post a call notification: \(error.localizedDescription)") }
        }
    }

    /// Someone calling while kvidr isn't in front: a banner with Answer and Decline. The ringing
    /// itself is kvidr's own, so the banner makes no sound of its own.
    func announceIncomingCall(_ conversation: Conversation) {
        let content = UNMutableNotificationContent()
        content.title = conversation.displayName
        content.body = conversation.isVideoCall ? String(localized: "Incoming video call") : String(localized: "Incoming call")
        content.categoryIdentifier = Self.incomingCallCategory
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["token": conversation.token, "incoming": true]
        let request = UNNotificationRequest(identifier: Self.incomingPrefix + conversation.token, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.notification.warning("Couldn’t post an incoming call: \(error.localizedDescription)") }
        }
    }

    func withdrawIncomingCall(token: String) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.incomingPrefix + token])
    }

    /// Takes down the banners for calls that have been answered, ended or missed.
    func withdrawCalls(ids: Set<Int>) {
        let identifiers = ids.map { Self.callPrefix + String($0) }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
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
            content.title = room.map { String(localized: "Reminder: \($0.displayName)", comment: "Notification title: %@ is the conversation") }
                ?? String(localized: "Reminder", comment: "Notification title for a message reminder")
            let sender = reminder.actor.resolvedDisplayName
            if preferences.showsNotificationPreviews, room?.isSensitive != true, !reminder.text.isEmpty {
                let preview = MessageContentParser(currentUserID: "", markdownEnabled: false)
                    .parse(Message(messageID: reminder.messageID, token: reminder.token, actor: reminder.actor,
                                   timestamp: reminder.date, text: reminder.text, parameters: reminder.parameters))
                    .preview
                content.subtitle = sender
                content.body = preview
            } else {
                content.body = sender.isEmpty
                    ? String(localized: "A message you asked to be reminded about")
                    : String(localized: "A message from \(sender)", comment: "Reminder notification body: %@ is who wrote the message")
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
        // Only a web link, and only one the server gave — checked again here, since this
        // is where it is opened.
        let action = response.actionIdentifier
        let isIncomingCall = userInfo["incoming"] as? Bool == true
        let joinLink = response.actionIdentifier == Self.joinAction
            ? (userInfo["link"] as? String).flatMap(URL.init(string:)).flatMap { $0.isWebLink ? $0 : nil }
            : nil
        await MainActor.run { [weak self] in
            if isIncomingCall, let token {
                if action == UNNotificationDismissActionIdentifier {
                    self?.onDeclineCall?(token)
                } else {
                    // Answer, or a click on the banner itself: both mean "take the call".
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    self?.onAnswerCall?(token)
                }
                return
            }
            if let joinLink {
                NSWorkspace.shared.open(joinLink)
                return
            }
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
