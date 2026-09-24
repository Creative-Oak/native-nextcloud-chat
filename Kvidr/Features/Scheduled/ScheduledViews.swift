import SwiftUI

/// A message waiting to be sent, at the foot of the conversation: the bubble drawn in outline
/// rather than filled — it hasn't gone anywhere yet — with when it will go underneath.
struct ScheduledMessageRow: View {
    let model: ChatModel
    let message: ScheduledMessage

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                if let parent = message.parent {
                    Text("↩︎ \(parent.actor.resolvedDisplayName): \(model.content(for: parentMessage(parent)).preview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    }
                    .frame(maxWidth: 520, alignment: .trailing)

                // Redrawn every few seconds, so the caption turns to "Sending…" when the time
                // comes without anything else having to change.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Label(caption(at: context.date), systemImage: message.hasFailed ? "exclamationmark.circle" : "clock")
                        .font(.caption2)
                        .foregroundStyle(message.hasFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contentShape(.rect)
        // AppKit's, made at the click: the row redraws every few seconds for its caption,
        // and a SwiftUI menu redrawn with it blinked its Change Time submenu.
        .popUpContextMenu {
            var times: [PopUpMenuItem] = ReminderPreset.presets().map { preset in
                .action(String(localized: "\(preset.title) — \(ReminderTime.text(preset.date))", comment: "A quick time: its name, then when it is")) { model.reschedule(message, to: preset.date) }
            }
            times.append(.divider)
            times.append(.action(String(localized: "Other Time…", comment: "Scheduled message menu: pick a time of your own")) { model.editScheduled(message) })
            return [
                .action(String(localized: "Send Now", comment: "Scheduled message menu")) { model.sendNow(message) },
                .submenu(String(localized: "Change Time", comment: "Scheduled message menu"), times),
                .action(String(localized: "Edit…", comment: "Scheduled message menu: edit the message")) { model.editScheduled(message) },
                .divider,
                .action(String(localized: "Delete", comment: "Scheduled message menu: delete the scheduled message")) { model.deleteScheduled(message) },
            ]
        }
        .accessibilityElement(children: .combine)
    }

    /// Past its time, it is waiting on the server: Nextcloud sends scheduled messages from a
    /// background job, which runs only as often as the server's cron does — often every five
    /// minutes. "Sending…" says that honestly, where a time already gone would look stuck.
    private func caption(at now: Date) -> String {
        if message.hasFailed { return String(localized: "Couldn’t be sent — right-click to try again", comment: "Under a scheduled message that failed") }
        if message.sendAt <= now { return String(localized: "Sending…", comment: "Under a scheduled message whose time has come") }
        // Whole sentences for today and tomorrow rather than "Sends" in front of
        // `ReminderTime`'s "Today 18:00": other languages lowercase the day mid-sentence.
        let calendar = Calendar.current
        let time = message.sendAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(message.sendAt) {
            return String(localized: "Sends Today \(time)", comment: "Under a scheduled message; %@ is a time of day")
        }
        if calendar.isDateInTomorrow(message.sendAt) {
            return String(localized: "Sends Tomorrow \(time)", comment: "Under a scheduled message; %@ is a time of day")
        }
        return String(localized: "Sends \(ReminderTime.text(message.sendAt))", comment: "Under a scheduled message; %@ is a weekday, date and time")
    }

    private func parentMessage(_ parent: ParentMessage) -> Message {
        Message(messageID: parent.messageID, token: model.token, actor: parent.actor,
                timestamp: parent.timestamp, text: parent.text, parameters: parent.parameters)
    }
}

/// Send Later, inside the message field: a dashed outline holding when the message will go,
/// edited in place with the system's own date field, and an × to send normally again. Drawn
/// after Messages' own.
struct SendLaterPill: View {
    @Bindable var model: ChatModel

    private var selection: Binding<Date> {
        Binding(get: { model.sendLater ?? Date() }, set: { model.sendLater = $0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)

            DatePicker(
                "Send at",
                selection: selection,
                in: Date().addingTimeInterval(60)...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()

            // The usual times, a click away, into the same field that stays editable.
            Menu {
                SendLaterPresets(model: model)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Quick times")

            if model.editingScheduled != nil {
                Text("Editing a scheduled message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.attachments.hasStaged {
                Text("Files can’t be scheduled")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 8)

            Button { model.cancelSendLater() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Send normally (Escape)")
            .accessibilityLabel("Don’t send later")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 1)
        // A rounded rectangle rather than a capsule: at the field's full width a capsule's
        // ends read as a separate control, where Messages' gentler corners sit inside the
        // taller field.
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
    }
}

/// The quick times for Send Later — each fills the capsule's field, which can then be moved
/// on from there.
struct SendLaterPresets: View {
    let model: ChatModel

    var body: some View {
        ForEach(ReminderPreset.presets()) { preset in
            Button("\(preset.title) — \(ReminderTime.text(preset.date))") {
                model.beginSendLater(at: preset.date)
            }
        }
    }
}
