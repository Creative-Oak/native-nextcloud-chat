import SwiftUI

/// The one-tap row under a message: "Add to Reminders", "Add to Notes".
///
/// Quiet by design. The chips are the width of their words, they sit under the bubble
/// rather than inside it, and a chip that has been used says so and stops being a button —
/// there is no second reminder to set, and a row that still offers one is a row that lies.
struct MessageSuggestionChips: View {
    let suggestions: [MessageSuggestion]
    /// The ones already acted on, kept by the transcript so scrolling away and back does
    /// not offer them again.
    let used: Set<String>
    var onActivate: (MessageSuggestion) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(suggestions) { suggestion in
                SuggestionChip(
                    suggestion: suggestion,
                    isUsed: used.contains(suggestion.id),
                    onActivate: onActivate
                )
            }
        }
        .padding(.top, 3)
        .animation(.smooth(duration: 0.2), value: used)
    }
}

/// One chip.
private struct SuggestionChip: View {
    let suggestion: MessageSuggestion
    let isUsed: Bool
    var onActivate: (MessageSuggestion) -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 4) {
                Image(systemName: isUsed ? "checkmark" : symbol(for: suggestion.kind))
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            // A concrete `Color` on both arms rather than two erased styles: the ternary
            // then has one type and no `AnyShapeStyle` boxing per render.
            .foregroundStyle(isUsed ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.primary.opacity(isUsed ? 0.05 : 0.09), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(isUsed)
        .help(help(for: suggestion))
        .accessibilityLabel(label)
    }

    private func activate() {
        onActivate(suggestion)
    }

    private var label: String {
        isUsed ? done(for: suggestion.kind) : title(for: suggestion.kind)
    }

    private func symbol(for kind: MessageSuggestion.Kind) -> String {
        switch kind {
        case .remind: "alarm"
        case .note: "note.text"
        }
    }

    private func title(for kind: MessageSuggestion.Kind) -> String {
        switch kind {
        case .remind: "Add to Reminders"
        case .note: "Add to Notes"
        }
    }

    private func done(for kind: MessageSuggestion.Kind) -> String {
        switch kind {
        case .remind: "Reminder set"
        case .note: "Added to Notes"
        }
    }

    /// The tooltip carries the detail the chip is too small for — which is where the time
    /// it read out of the message goes, so nobody has to guess what "i morgen" became.
    private func help(for suggestion: MessageSuggestion) -> String {
        switch suggestion.kind {
        case .remind(let date):
            if let phrase = suggestion.phrase {
                "Remind you about this — “\(phrase)”, which is \(ReminderTime.text(date))"
            } else {
                "Remind you about this at \(ReminderTime.text(date))"
            }
        case .note:
            "Send this to your Note to self conversation"
        }
    }
}

/// Replies you could send without typing, above the message field.
struct SmartReplyBar: View {
    let replies: [String]
    var onPick: (String) -> Void

    var body: some View {
        // One container for the row, at the spacing that keeps three separate suggestions
        // three separate shapes — they share it for rendering, not to merge.
        GlassEffectContainer(spacing: GlassSpacing.distinct) {
            HStack(spacing: 6) {
                ForEach(replies, id: \.self) { reply in
                    SmartReplyChip(reply: reply, onPick: onPick)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// One suggested reply.
private struct SmartReplyChip: View {
    let reply: String
    var onPick: (String) -> Void

    var body: some View {
        Button(action: pick) {
            Text(reply)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glass(.chip)
        .help("Put this in the message field")
    }

    private func pick() {
        onPick(reply)
    }
}

/// The reminder armed by clicking a time in your own draft, sitting in the field above the
/// words that will carry it — the same place Send Later sits, because it is the same idea:
/// something that will happen when this message goes.
struct ArmedReminderPill: View {
    let armed: ArmedReminder
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Text("Remind me \(ReminderTime.text(armed.date))")
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Text("“\(armed.phrase)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Don’t set a reminder")
            .accessibilityLabel("Cancel the reminder")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 1)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
    }
}
