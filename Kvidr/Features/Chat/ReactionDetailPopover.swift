import SwiftUI

/// Who reacted, and with what.
///
/// Loads on open rather than with every message — a conversation of a thousand messages
/// should not be a thousand requests for names nobody asked to see.
struct ReactionDetailPopover: View {
    let message: Message
    let session: Session

    @State private var detail: [String: [ReactionActor]] = [:]
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading && detail.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if detail.isEmpty {
                Text("No reactions").font(.callout).foregroundStyle(.secondary)
            }

            ForEach(ordered, id: \.0) { emoji, actors in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(emoji).font(.system(size: 15))
                        Text("\(actors.count)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ForEach(actors) { reaction in
                        HStack(spacing: 6) {
                            ActorAvatarView(actor: reaction.actor, size: 18)
                            Text(reaction.actor.resolvedDisplayName)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220)
        .task { await load() }
    }

    private var ordered: [(String, [ReactionActor])] {
        detail.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .map { ($0.key, $0.value) }
    }

    private func load() async {
        defer { isLoading = false }
        detail = (try? await session.reactions.reactionDetail(token: message.token, messageID: message.messageID)) ?? [:]
    }
}
