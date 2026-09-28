import EventKit
import Foundation
import FoundationModels
import SwiftUI

/// A message's meeting into Calendar, or its to-do into Reminders — right-click, check what
/// it says, add. The day and time come from the system's date detector; Apple Intelligence
/// suggests the title, the place and how long, which it's good at, and not the date, which it
/// isn't. Nothing is added without the sheet's Add.
@MainActor
enum MessageToCalendar {
    /// What the sheets start from.
    struct Draft: Identifiable {
        let id = UUID()
        var title: String
        var start: Date
        var hasTime: Bool
        var minutes: Int
        var location: String
        var notes: String
        var url: URL?
    }

    @Generable
    struct Suggestion {
        @Guide(description: "A short title for it, as it would appear in a calendar or a to-do list — a few words, in the message's language, no date or time in it.")
        var title: String
        @Guide(description: "Where it happens, if the message says; empty otherwise.")
        var location: String
        @Guide(description: "How many minutes it takes, if the message suggests it; 60 otherwise.", .range(5...600))
        var minutes: Int
    }

    /// The draft for `text`: the date found in it, and Apple Intelligence's title — or, without
    /// it, the message's first words.
    static func draft(from text: String, author: String, conversation: String, url: URL?, forTask: Bool) async -> Draft {
        let mention = DateMention.first(in: text)
        let fallbackTitle = String(text.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = Draft(
            title: fallbackTitle,
            start: mention?.date ?? Self.nextHour(),
            hasTime: mention?.hasTime ?? !forTask,
            minutes: mention?.duration.map { Int($0 / 60) } ?? 60,
            location: "",
            notes: String(localized: "\(author) in \(conversation):\n\(text)", comment: "Notes of a calendar event or reminder made from a message: the author, the conversation, then the message"),
            url: url
        )
        guard case .available = UnreadSummary.availability else { return draft }
        let session = LanguageModelSession(instructions: forTask
            ? "You turn a chat message into a to-do for the person reading it. The title says what to do, like “Send Anna the draft”."
            : "You turn a chat message into a calendar event. The title says what the event is, like “Budget meeting with Anna”.")
        if let suggestion = try? await session.respond(to: "From \(author):\n\(text)", generating: Suggestion.self).content {
            if !suggestion.title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = suggestion.title }
            draft.location = suggestion.location
            if mention?.duration == nil { draft.minutes = suggestion.minutes }
        }
        return draft
    }

    private static func nextHour() -> Date {
        Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
    }

    // MARK: - Saving

    private static let store = EKEventStore()

    static func addEvent(_ draft: Draft) async throws {
        guard try await store.requestWriteOnlyAccessToEvents() else { throw AddError.noAccessToCalendar }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.isAllDay = !draft.hasTime
        event.startDate = draft.hasTime ? draft.start : Calendar.current.startOfDay(for: draft.start)
        event.endDate = draft.hasTime ? draft.start.addingTimeInterval(TimeInterval(draft.minutes * 60)) : event.startDate
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes
        event.url = draft.url
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }

    static func addReminder(_ draft: Draft, isDue: Bool) async throws {
        guard try await store.requestFullAccessToReminders() else { throw AddError.noAccessToReminders }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.url = draft.url
        reminder.calendar = store.defaultCalendarForNewReminders()
        if isDue {
            let fields: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: draft.start)
            if draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: draft.start)) }
        }
        try store.save(reminder, commit: true)
    }

    enum AddError: LocalizedError {
        case noAccessToCalendar
        case noAccessToReminders

        var errorDescription: String? {
            switch self {
            case .noAccessToCalendar:
                String(localized: "kvidr isn’t allowed to add to Calendar. Allow it in System Settings → Privacy & Security → Calendar.", comment: "Use the names of the Calendar app and of the settings as macOS shows them")
            case .noAccessToReminders:
                String(localized: "kvidr isn’t allowed to add to Reminders. Allow it in System Settings → Privacy & Security → Reminders.", comment: "Use the names of the Reminders app and of the settings as macOS shows them")
            }
        }
    }
}

/// Add to Calendar… or Add to Reminders…: the draft, to check and change, then Add.
struct AddFromMessageSheet: View {
    enum Kind { case event, reminder }

    let kind: Kind
    /// Reads the message and suggests; given here so the sheet can show itself at once.
    let makeDraft: () async -> MessageToCalendar.Draft

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MessageToCalendar.Draft?
    @State private var isDue = true
    @State private var problem: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind == .event ? "Add to Calendar" : "Add to Reminders")
                .font(.headline)
                .padding(16)
            Divider()
            if let binding = Binding($draft) {
                Form {
                    TextField("Title", text: binding.title)
                    if kind == .reminder {
                        Toggle("Remind me on a day", isOn: $isDue)
                    }
                    if kind == .event || isDue {
                        Toggle("At a time", isOn: binding.hasTime)
                        DatePicker(kind == .event ? "Starts" : "Due", selection: binding.start, displayedComponents: binding.wrappedValue.hasTime ? [.date, .hourAndMinute] : [.date])
                    }
                    if kind == .event {
                        if binding.wrappedValue.hasTime {
                            Stepper("\(binding.wrappedValue.minutes) minutes", value: binding.minutes, in: 5...600, step: 15)
                        }
                        TextField("Location", text: binding.location)
                    }
                    Section("Notes") {
                        Text(binding.wrappedValue.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .formStyle(.grouped)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Label("Reading the message…", systemImage: "apple.intelligence")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
            Divider()
            HStack {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || draft?.title.trimmingCharacters(in: .whitespaces).isEmpty == true || isAdding)
            }
            .padding(16)
        }
        .frame(width: 420, height: kind == .event ? 470 : 420)
        .task { draft = await makeDraft() }
    }

    private func add() {
        guard let draft else { return }
        isAdding = true
        problem = nil
        Task {
            do {
                switch kind {
                case .event: try await MessageToCalendar.addEvent(draft)
                case .reminder: try await MessageToCalendar.addReminder(draft, isDue: isDue)
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            isAdding = false
        }
    }
}
