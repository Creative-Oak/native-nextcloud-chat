import SwiftUI

/// The call's React button: raise your hand, or send an emoji everyone sees float up.
struct ReactButton: View {
    let call: CallController
    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 7) {
            Button { isOpen.toggle() } label: {
                Image(systemName: call.isHandRaised ? "hand.raised.fill" : "face.smiling")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(call.isHandRaised ? .black : .white)
                    .frame(width: 62, height: 62)
                    .background {
                        if call.isHandRaised { Circle().fill(.white) }
                    }
                    .glassEffect(call.isHandRaised ? .identity : .regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Raise your hand, or react")
            .accessibilityLabel("React")
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                ReactionPicker(call: call) { isOpen = false }
            }
            Text("React")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
        // ⇧⌘R raises or lowers the hand without opening anything.
        .background {
            Button("", action: call.toggleHand)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// Raise Hand, then the server's emoji in rows.
private struct ReactionPicker: View {
    let call: CallController
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button {
                call.toggleHand()
                onDone()
            } label: {
                Label(call.isHandRaised ? "Lower Hand" : "Raise Hand", systemImage: call.isHandRaised ? "hand.raised.slash" : "hand.raised")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 6), spacing: 4) {
                ForEach(call.reactionChoices, id: \.self) { emoji in
                    Button {
                        call.react(emoji)
                        onDone()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(width: 40, height: 40)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("React with \(emoji)")
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// Emoji people sent, each rising from the bottom of the stage with who sent it, and fading
/// as it goes — as Talk's web app shows them. Still, with Reduce Motion: they appear and go.
struct ReactionsOverlay: View {
    let reactions: [CallController.Reaction]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                ForEach(reactions) { reaction in
                    FloatingReaction(reaction: reaction, height: proxy.size.height)
                        // Each its own lane, so a burst of them doesn't pile on one spot.
                        .offset(x: lane(for: reaction) * min(proxy.size.width * 0.3, 220))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func lane(for reaction: CallController.Reaction) -> CGFloat {
        CGFloat(abs(reaction.id.hashValue % 1000)) / 1000
    }
}

private struct FloatingReaction: View {
    let reaction: CallController.Reaction
    let height: CGFloat

    @State private var isRisen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            Text(reaction.emoji)
                .font(.system(size: 42))
            Text(reaction.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.black.opacity(0.45), in: .capsule)
        }
        .offset(y: isRisen && !reduceMotion ? -height * 0.55 : 0)
        .opacity(isRisen ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 3.6)) { isRisen = true }
        }
    }
}

/// A raised hand, on a tile or beside a picture.
struct HandBadge: View {
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: size * 2.2, height: size * 2.2)
            .background(.yellow, in: .circle)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .accessibilityLabel("Hand raised")
    }
}

/// Everyone in the call, beside the stage: raised hands first, in the order they went up, then
/// the rest; whether each can be heard and seen; and, for a moderator, Mute.
struct CallPeoplePanel: View {
    let call: CallController
    let me: MessageActor
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In the Call")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(call.participants.count + 1)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(14)

            ScrollView {
                VStack(spacing: 2) {
                    row(actor: me, name: "\(me.resolvedDisplayName) (you)", isAudioOn: !call.isMuted, isVideoOn: call.isCameraOn, isHandRaised: call.isHandRaised, isSpeaking: call.isSpeaking, mute: nil)
                    ForEach(ordered) { participant in
                        row(
                            actor: participant.actor,
                            name: participant.name,
                            isAudioOn: participant.isAudioOn,
                            isVideoOn: participant.isVideoOn,
                            isHandRaised: participant.isHandRaised,
                            isSpeaking: participant.isSpeaking,
                            mute: call.canMuteOthers && participant.isAudioOn ? { call.forceMute(participant.id) } : nil
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 270)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var ordered: [CallController.Participant] {
        call.participants.sorted { lhs, rhs in
            switch (lhs.handRaisedAt, rhs.handRaisedAt) {
            case let (l?, r?): l < r
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func row(actor: MessageActor, name: String, isAudioOn: Bool, isVideoOn: Bool, isHandRaised: Bool, isSpeaking: Bool, mute: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            ActorAvatarView(actor: actor, size: 30)
                .speakingRing(isSpeaking, lineWidth: 2)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHandRaised {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Hand raised")
            }
            Image(systemName: isVideoOn ? "video.fill" : "video.slash.fill")
                .foregroundStyle(.white.opacity(isVideoOn ? 0.9 : 0.45))
                .accessibilityLabel(isVideoOn ? "Camera on" : "Camera off")
            Image(systemName: isAudioOn ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(.white.opacity(isAudioOn ? 0.9 : 0.45))
                .accessibilityLabel(isAudioOn ? "Microphone on" : "Muted")
            if let mute {
                Button("Mute", action: mute)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Mute \(name) — they can unmute themselves")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
