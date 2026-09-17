import SwiftUI

/// Someone is typing: the three dots in a bubble at the foot of the transcript, where their
/// message will land, as in Messages. In a group, who it is sits above, the way a sender's
/// name does.
struct TypingIndicatorRow: View {
    let typists: [TypingTracker.Typist]
    let conversation: Conversation

    private var summary: String {
        TypingSummary.text(names: typists.map { $0.displayName ?? (conversation.isOneToOne ? conversation.displayName : nil) })
            ?? "Someone is typing…"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if let first = typists.first, let user = first.userID {
                    ActorAvatarView(actor: MessageActor(kind: .users, id: user, displayName: first.displayName ?? ""), size: 28)
                } else {
                    ActorAvatarView(actor: MessageActor(kind: .guests, id: "", displayName: ""), size: 28)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if !conversation.isOneToOne {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                TypingDots()
                    .messageBubble(isFromMe: false)
            }
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}

/// Three dots that swell and fade in turn; still, and a little dimmer, with Reduce Motion.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion ? 0.5 : (sin((time * 2 * .pi / 1.2) - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.55 * wave)
                        .scaleEffect(0.85 + 0.2 * wave)
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 2)
        }
    }
}
