import SwiftUI

/// Someone calling: who, what kind of call, and two round buttons — decline and answer — as
/// FaceTime's call notice has them on the Mac.
struct IncomingCallBanner: View {
    let ringing: IncomingCalls.Ringing
    var onAnswer: () -> Void
    var onDecline: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVideo: Bool { ringing.conversation.isVideoCall }

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(conversation: ringing.conversation, size: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(ringing.conversation.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Label(isVideo ? "Incoming video call" : "Incoming call", systemImage: isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 8)

            Button(action: onDecline) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Decline")
            .accessibilityLabel("Decline")

            Button(action: onAnswer) {
                Image(systemName: isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.green, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Answer")
            .accessibilityLabel("Answer")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(width: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 27))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
        // A little hop every so often while it rings, to catch the eye; still with Reduce Motion.
        .keyframeAnimator(initialValue: CGFloat.zero, repeating: !reduceMotion) { content, lift in
            content.offset(y: lift)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-7, duration: 0.16, spring: .snappy)
                SpringKeyframe(0, duration: 0.34, spring: .bouncy)
                SpringKeyframe(-3, duration: 0.14, spring: .snappy)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                LinearKeyframe(0, duration: 1.2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ringing.conversation.displayName) is calling")
    }
}
