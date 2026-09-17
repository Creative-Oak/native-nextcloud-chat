import Foundation
import Observation

/// The user's reminders on messages: the upcoming list, setting and removing one, and
/// keeping macOS's scheduled notifications in step with them.
///
/// The notifications are scheduled with macOS rather than raised when kvidr notices a
/// reminder is due, so one arrives on time even while kvidr is quit.
@MainActor
@Observable
final class ReminderStore {
    /// Soonest first. Past ones are dropped as they come due.
    private(set) var reminders: [Reminder] = []

    let session: Session
    /// Reminders.app, for the destinations that include it.
    let apple: AppleRemindersService
    @ObservationIgnored private let notifications: NotificationController
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// Where a reminder's conversation name, and whether it is sensitive, come from.
    @ObservationIgnored var conversation: (String) -> Conversation? = { _ in nil }

    init(
        session: Session,
        notifications: NotificationController,
        preferences: Preferences,
        apple: AppleRemindersService = AppleRemindersService()
    ) {
        self.session = session
        self.notifications = notifications
        self.preferences = preferences
        self.apple = apple
    }

    var canSetReminders: Bool { session.capabilitySnapshot.supportsReminders }

    /// Whether a reminder can be set at all — either the server takes them, or the user
    /// keeps them in Reminders.app, where the server's opinion doesn't come into it.
    var canRemind: Bool {
        (canSetReminders && preferences.reminderDestination.includesTalk)
            || preferences.reminderDestination.includesApple
    }

    /// Sets a reminder about a message, wherever this user keeps them.
    ///
    /// The one door every "remind me" in the app comes through — the message menu, the
    /// chip under a bubble, and a time clicked in your own draft — so the choice in
    /// Settings is honoured in one place rather than three.
    func remind(about message: Message, at date: Date) {
        let destination = preferences.reminderDestination
        if destination.includesTalk, canSetReminders {
            set(on: message, at: date)
        }
        guard destination.includesApple else { return }

        let room = conversation(message.token)
        let isSensitive = room?.isSensitive == true
        // A sensitive conversation's words do not get copied into another app's database.
        let body = isSensitive ? ConversationPreview.hiddenText : message.text
        let who = message.actor.resolvedDisplayName
        let title = body.isEmpty ? "Message from \(who)" : "\(who): \(body.prefix(80))"
        let notes = [room?.displayName, isSensitive ? nil : (body.count > 80 ? body : nil)]
            .compactMap { $0 }
            .joined(separator: "\n\n")

        Task { [apple] in
            await apple.add(title: title, notes: notes.isEmpty ? nil : notes, due: date)
        }
    }

    func reminder(token: String, messageID: Int) -> Reminder? {
        reminders.first { $0.token == token && $0.messageID == messageID }
    }

    /// Reads the upcoming list from the server. At sign-in and whenever kvidr comes to the
    /// front, since reminders set on the web or a phone should show up here too.
    func load() async {
        guard session.capabilitySnapshot.supportsUpcomingReminders else { return }
        do throws(TalkError) {
            let fresh = try await session.reminders.upcoming()
            reminders = fresh.filter { $0.date > Date() }
            remindersChanged()
        } catch {
            Log.ui.warning("Couldn’t load reminders: \(error.userMessage)")
        }
    }

    func set(on message: Message, at date: Date) {
        guard canSetReminders, message.messageID > 0 else { return }
        let previous = reminders
        let reminder = Reminder(
            token: message.token,
            messageID: message.messageID,
            date: date,
            actor: message.actor,
            text: message.text,
            parameters: message.parameters
        )
        reminders.removeAll { $0.id == reminder.id }
        reminders.append(reminder)
        reminders.sort { $0.date < $1.date }
        remindersChanged()

        let service = session.reminders
        Task { [weak self] in
            do throws(TalkError) {
                try await service.setReminder(token: reminder.token, messageID: reminder.messageID, at: date)
            } catch {
                self?.reminders = previous
                self?.remindersChanged()
                Log.ui.warning("Couldn’t set reminder: \(error.userMessage)")
            }
        }
    }

    func remove(_ reminder: Reminder) {
        let previous = reminders
        reminders.removeAll { $0.id == reminder.id }
        remindersChanged()

        let service = session.reminders
        Task { [weak self] in
            do throws(TalkError) {
                try await service.deleteReminder(token: reminder.token, messageID: reminder.messageID)
            } catch .notFound {
                // Already gone — it came due, or was removed elsewhere. Nothing to put back.
            } catch {
                self?.reminders = previous
                self?.remindersChanged()
                Log.ui.warning("Couldn’t remove reminder: \(error.userMessage)")
            }
        }
    }

    /// Signing out: nothing of this account's should still go off.
    func tearDown() {
        expiryTask?.cancel()
        reminders = []
        notifications.scheduleReminders([], conversation: conversation)
    }

    private func remindersChanged() {
        notifications.scheduleReminders(reminders, conversation: conversation)
        scheduleExpiry()
    }

    /// Takes each reminder off the list the moment it comes due, as the server does.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = reminders.map(\.date).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0) + 1))
            guard !Task.isCancelled, let self else { return }
            self.reminders.removeAll { $0.date <= Date() }
            self.scheduleExpiry()
        }
    }
}
