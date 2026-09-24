import AppKit
import SwiftUI

/// The sidebar's Reminders row, at the top of the list while there are any — where Mail
/// keeps Remind Me. A quiet line rather than a conversation-sized row: the alarm at the
/// faces' left edge, the name beside it, and the count where a sidebar keeps its counts. The
/// alarm stays orange when the row is selected, as Reminders' own lists keep their colour.
struct RemindersSidebarRow: View {
    let count: Int

    var body: some View {
        SidebarShortcutRow(title: String(localized: "Reminders", comment: "Sidebar row and page title"), systemImage: "alarm", iconStyle: AnyShapeStyle(Color.orange), count: count)
            .accessibilityLabel("Reminders, \(count) upcoming")
    }
}

/// A line at the top of the sidebar that isn't a conversation — Reminders, Catch Up: its
/// symbol lined up with the avatars' left edge under it, and a count.
struct SidebarShortcutRow: View {
    let title: String
    let systemImage: String
    let iconStyle: AnyShapeStyle
    let count: Int

    /// `ConversationRow`'s unread gutter and the space after it: where the avatars start.
    private static let leading: CGFloat = 13

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconStyle)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.leading, Self.leading - 2)
        .padding(.vertical, 3)
        .badge(count)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Every upcoming reminder in the messages column, the way the Reminders app lists them: the
/// title large in the list's colour with the count opposite, then the reminders by day,
/// soonest first. A click opens the message in its conversation.
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
                    header
                        .listRowSeparator(.hidden)
                    ForEach(days, id: \.day) { group in
                        Section {
                            ForEach(group.reminders) { reminder in
                                ReminderRow(
                                    reminder: reminder,
                                    conversation: app.conversationList?[reminder.token],
                                    onOpen: { app.openMessage(token: reminder.token, messageID: reminder.messageID) },
                                    onRemove: { store.remove(reminder) }
                                )
                            }
                        } header: {
                            Text(Self.title(of: group.day))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Reminders")
        .task { await store.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Reminders")
                .foregroundStyle(.orange)
            Spacer()
            Text("\(store.reminders.count)")
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
        .font(.system(size: 26, weight: .bold))
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private struct Day {
        let day: Date
        let reminders: [Reminder]
    }

    /// The reminders by the day they're due, in order.
    private var days: [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for reminder in store.reminders.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: reminder.date)
            if result.last?.day == day {
                result[result.count - 1] = Day(day: day, reminders: result[result.count - 1].reminders + [reminder])
            } else {
                result.append(Day(day: day, reminders: [reminder]))
            }
        }
        return result
    }

    /// "Today", "Tomorrow", "Monday 28 September" — with the year only when it isn't this one.
    private static func title(of day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today", comment: "Reminders page: heading over today's reminders") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow", comment: "Reminders page: heading over tomorrow's reminders") }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

private struct ReminderRow: View {
    let reminder: Reminder
    let conversation: Conversation?
    var onOpen: () -> Void
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation?.displayName ?? reminder.actor.resolvedDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Label(reminder.date.formatted(date: .omitted, time: .shortened), systemImage: "alarm")
                .labelStyle(ReminderTimeLabelStyle())
                .font(.system(size: 12))
                .monospacedDigit()

            // Kept in the layout while hidden, so the time doesn't shift when the pointer comes.
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(isHovering ? 1 : 0)
            .help("Remove Reminder")
            .accessibilityLabel("Remove Reminder")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Show Message", action: onOpen)
            Divider()
            Button("Remove Reminder", role: .destructive, action: onRemove)
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .listRowSeparator(.visible)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove Reminder", onRemove)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var avatar: some View {
        if let conversation {
            AvatarView(conversation: conversation, size: 32)
        } else {
            ActorAvatarView(actor: reminder.actor, size: 32)
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
        return isGroup ? String(localized: "\(reminder.actor.resolvedDisplayName): \(text)", comment: "Message preview: the author's name, then the message") : text
    }
}

/// The alarm in orange, the time beside it in grey.
private struct ReminderTimeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.orange)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// How a reminder's time reads: "Today 18:00", "Tomorrow 09:00", "Mon 21 Sep 09:00".
enum ReminderTime {
    static func text(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)", comment: "When a reminder or scheduled message is due; %@ is a time of day") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow \(time)", comment: "When a reminder or scheduled message is due; %@ is a time of day") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// Remind Me → Custom…: a day and a time of your own, from a minute from now on. Starts at
/// the next full hour, the likeliest one to want.
struct CustomReminderSheet: View {
    var onSet: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remind Me")
                .font(.headline)
            // The day on a calendar and the time typed beside it, rather than the clock face a
            // graphical picker puts there: a time is quicker typed than dragged.
            HStack(alignment: .top, spacing: 16) {
                DatePicker("Day", selection: day, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Time")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text(ReminderTime.text(date))
                        .font(.system(size: 12))
                        .foregroundStyle(date <= .now ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Reminder") {
                    onSet(date)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(date <= .now)
            }
        }
        .padding(18)
        .fixedSize()
    }

    /// The day picked on the calendar, keeping the time.
    private var day: Binding<Date> {
        Binding(get: { date }, set: { date = Self.combine(day: $0, time: date) })
    }

    /// The time typed, keeping the day.
    private var time: Binding<Date> {
        Binding(get: { date }, set: { date = Self.combine(day: date, time: $0) })
    }

    private static func combine(day: Date, time: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        parts.hour = clock.hour
        parts.minute = clock.minute
        return calendar.date(from: parts) ?? day
    }
}
