import EventKit
import Foundation
import Observation

/// Reminders.app, for the people who live in it.
///
/// Nextcloud's own reminders are the default and the better answer in most ways — they
/// follow you to your phone and the web, and they cost no permission at all. This is here
/// because a reminder about a message is still a reminder, and for a lot of people the
/// place they will actually look is the Reminders app on their Dock.
///
/// Access is asked for at the moment it is first needed, never at launch: a chat client
/// that asks for your reminders while you are signing in has not earned the question.
@MainActor
@Observable
final class AppleRemindersService {
    enum Access: Equatable {
        case unknown
        case granted
        /// Refused, or barred by policy. The reason is worth showing once, in Settings.
        case denied(String)
    }

    private(set) var access: Access = .unknown

    @ObservationIgnored private let store = EKEventStore()

    init() {
        refreshAccess()
    }

    /// What macOS already thinks, without asking the user anything.
    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            access = .granted
        case .denied, .restricted:
            access = .denied("kvidr was refused access to Reminders. You can change that in System Settings › Privacy & Security › Reminders.")
        default:
            access = .unknown
        }
    }

    /// Asks, if it hasn't been asked before. `true` means a reminder can be written.
    @discardableResult
    func requestAccess() async -> Bool {
        if case .granted = access { return true }
        do {
            let granted = try await store.requestFullAccessToReminders()
            access = granted
                ? .granted
                : .denied("kvidr was refused access to Reminders. You can change that in System Settings › Privacy & Security › Reminders.")
            return granted
        } catch {
            access = .denied(error.localizedDescription)
            Log.ui.warning("Couldn’t ask for Reminders access: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes one reminder into the user's default list, with an alarm at the time so it
    /// actually goes off rather than just sitting there.
    ///
    /// The message itself goes in the notes, not the title: a title is what you see in a
    /// list of forty, and "Heine: kan du kigge på fakturaen" is more use there than the
    /// first line of a paragraph.
    func add(title: String, notes: String?, due: Date) async {
        guard await requestAccess() else { return }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            Log.ui.warning("No default Reminders list to write to.")
            return
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due
        )
        reminder.addAlarm(EKAlarm(absoluteDate: due))

        do {
            try store.save(reminder, commit: true)
        } catch {
            Log.ui.warning("Couldn’t save a reminder: \(error.localizedDescription)")
        }
    }
}

/// Where a reminder set in kvidr ends up.
enum ReminderDestination: String, CaseIterable, Sendable {
    /// Nextcloud's own — syncs to Talk on your phone and in the browser.
    case talk
    /// Reminders.app on this Mac, and wherever your Apple account takes it.
    case apple
    /// Both, for people who read one and act in the other.
    case both

    var title: String {
        switch self {
        case .talk: "Nextcloud"
        case .apple: "Apple Reminders"
        case .both: "Both"
        }
    }

    var includesTalk: Bool { self != .apple }
    var includesApple: Bool { self != .talk }
}
