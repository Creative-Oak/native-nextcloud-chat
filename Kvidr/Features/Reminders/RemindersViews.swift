import AppKit
import SwiftUI

/// The sidebar's Reminders row, at the top of the list while there are any — where Mail
/// keeps Remind Me. A quiet line rather than a conversation-sized row: a symbol in the
/// avatars' column, so it lines up with the faces under it, the name, and the count.
struct RemindersSidebarRow: View {
    let count: Int
    var isSelected = false

    /// `ConversationRow`'s unread gutter and avatar column.
    private static let gutter: CGFloat = 8
    private static let avatar: CGFloat = 40

    var body: some View {
        HStack(spacing: 5) {
            Color.clear
                .frame(width: Self.gutter, height: 1)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                Image(systemName: "alarm")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .orange)
                    .frame(width: Self.avatar)

                Text("Reminders")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reminders, \(count) upcoming")
    }
}

/// Every upcoming reminder, soonest first, in the messages column. A click opens the message
/// in its conversation.
struct RemindersPage: View {
    let store: ReminderStore
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if store.reminders.isEmpty {
                ContentUnavailableView {
                    Label("No Reminders", systemImage: "alarm")
                } description: {
                    Text("Right-click a message and choose Remind Me to be reminded about it later.")
                }
            } else {
                List {
                    ForEach(store.reminders) { reminder in
                        ReminderRow(
                            reminder: reminder,
                            conversation: app.conversationList?[reminder.token],
                            onOpen: { app.openMessage(token: reminder.token, messageID: reminder.messageID) },
                            onRemove: { store.remove(reminder) }
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 560)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Reminders")
        .task { await store.load() }
    }
}

private struct ReminderRow: View {
    let reminder: Reminder
    let conversation: Conversation?
    var onOpen: () -> Void
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ActorAvatarView(actor: reminder.actor, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(conversation?.displayName ?? reminder.actor.resolvedDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Where the hover's remove button isn't: the two take turns.
                    if isHovering {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove Reminder")
                        .accessibilityLabel("Remove Reminder")
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "alarm")
                                .foregroundStyle(.orange)
                            Text(ReminderTime.text(reminder.date))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    }
                }
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Show Message", action: onOpen)
            Button("Remove Reminder", action: onRemove)
        }
    }

    private var preview: String {
        if conversation?.isSensitive == true { return ConversationPreview.hiddenText }
        let message = Message(
            messageID: reminder.messageID, token: reminder.token, actor: reminder.actor,
            timestamp: reminder.date, text: reminder.text, parameters: reminder.parameters
        )
        let text = MessageContentParser(currentUserID: "", markdownEnabled: false).parse(message).preview
        let isGroup = conversation.map { !$0.isOneToOne } ?? true
        return isGroup ? "\(reminder.actor.resolvedDisplayName): \(text)" : text
    }
}

/// How a reminder's time reads: "Today 18:00", "Tomorrow 09:00", "Mon 21 Sep 09:00".
enum ReminderTime {
    static func text(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
