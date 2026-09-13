import SwiftUI

/// The `@`-autocomplete popover.
struct MentionSuggestionList: View {
    let suggestions: [MentionSuggestion]
    let highlighted: Int
    var onPick: (MentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion, isHighlighted: index == highlighted)
                    .contentShape(.rect)
                    .onTapGesture { onPick(suggestion) }
            }
        }
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityLabel("Mention suggestions")
    }

    private func row(_ suggestion: MentionSuggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            icon(for: suggestion)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(suggestion.label)
                    .lineLimit(1)
                if let detail = detail(for: suggestion) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let status = suggestion.status, status.isOnline {
                Circle().fill(.green).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isHighlighted ? Color.accentColor.opacity(0.2) : .clear)
    }

    @ViewBuilder
    private func icon(for suggestion: MentionSuggestion) -> some View {
        switch suggestion.source {
        case .calls:
            Image(systemName: "megaphone").foregroundStyle(Color.accentColor)
        case .groups:
            Image(systemName: "person.2").foregroundStyle(.secondary)
        case .guests:
            Image(systemName: "person.crop.circle.dashed").foregroundStyle(.secondary)
        case .federatedUsers:
            Image(systemName: "globe").foregroundStyle(.secondary)
        default:
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
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
