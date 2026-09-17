import SwiftUI

/// Over the message field when you are writing to somebody who is out of office: what you
/// have typed will sit unread until they are back, and one click sends it when they are.
///
/// No model involved — the server already told us they are away and until when. It is here
/// because it is the same idea as everything else in this corner of the app: the client
/// noticing something you would have had to notice yourself.
///
/// Offered, never applied. It appears once you have typed something, it can be waved away,
/// and Send Later's own field is what it fills in — so the time stays yours to change.
struct AbsenceSendLaterBar: View {
    let name: String
    let absence: Absence
    /// The morning they are back, worked out by ``Absence/firstMorningBack(calendar:hour:now:)``.
    let sendAt: Date
    var onSchedule: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "airplane")
                .font(.system(size: 10))
                .foregroundStyle(.orange)

            Text("\(firstName) is away until \(until)")
                .lineLimit(1)

            Button(action: onSchedule) {
                Text("Send \(ReminderTime.text(sendAt))")
            }
            .buttonStyle(.link)
            .fixedSize()
            .help("Hold this message until \(sendAt.formatted(date: .complete, time: .shortened))")

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Send it now anyway")
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glass(.panel, cornerRadius: 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
    }

    private var until: String {
        absence.lastDay().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
