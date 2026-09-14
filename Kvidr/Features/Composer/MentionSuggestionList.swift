import SwiftUI

/// The `@`-autocomplete popover.
struct MentionSuggestionList: View {
    let suggestions: [MentionSuggestion]
    let highlighted: Int
    var onPick: (MentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion, isHighlighted: index == highlighted)
                    .contentShape(.rect)
                    .onTapGesture { onPick(suggestion) }
            }
        }
        // Inset, so the highlight is a rounded pill inside the panel rather than a band
        // running edge to edge across it.
        .padding(5)
        .frame(width: 300, alignment: .leading)
        .glass(.panel, cornerRadius: 14)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .accessibilityLabel("Mention suggestions")
    }

    private func row(_ suggestion: MentionSuggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            avatar(for: suggestion)

            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail = detail(for: suggestion) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75))
                                                       : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let status = suggestion.status, status.isOnline {
                Circle()
                    .fill(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(Color.green))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Online")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        // A solid accent fill with white on top, the way a real menu highlights — the old
        // 20% wash left the text at the same weight and read as a smudge.
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
    }

    /// People get their real avatar; the entries that aren't a person get a glyph in a
    /// circle of the same size, so the column of icons stays a column.
    @ViewBuilder
    private func avatar(for suggestion: MentionSuggestion) -> some View {
        switch suggestion.source {
        case .users, .federatedUsers:
            ActorAvatarView(
                actor: MessageActor(
                    kind: suggestion.source == .users ? .users : .federatedUsers,
                    id: suggestion.id,
                    displayName: suggestion.label
                ),
                size: 24
            )
        default:
            ZStack {
                Circle().fill(.quaternary)
                Image(systemName: symbol(for: suggestion.source))
                    .font(.system(size: 11))
            }
            .frame(width: 24, height: 24)
        }
    }

    private func symbol(for source: MentionSuggestion.Source) -> String {
        switch source {
        case .calls: "megaphone"
        case .groups: "person.2"
        case .guests: "person.crop.circle.dashed"
        default: "person.crop.circle"
        }
    }

    private func detail(for suggestion: MentionSuggestion) -> String? {
        if let details = suggestion.details, !details.isEmpty { return details }
        if let message = suggestion.status?.message, !message.isEmpty {
            return [suggestion.status?.icon, message].compactMap { $0 }.joined(separator: " ")
        }
        if suggestion.source == .federatedUsers { return suggestion.id }
        return nil
    }
}
