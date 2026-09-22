import AppKit
import SwiftUI

/// A call running in a conversation: the marker for it, and the way in — here, or in the
/// browser while this Mac is in another call.

/// The symbol for a running call, green as calls are everywhere on the Mac.
struct CallSymbol: View {
    let conversation: Conversation
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: conversation.isVideoCall ? "video.fill" : "phone.fill")
            .font(.system(size: size))
            .foregroundStyle(.green)
            .help("Call in progress")
            .accessibilityLabel("Call in progress")
    }
}

/// The running-call marker on a face in the compact sidebar and the favourites grid: the
/// symbol on a green disc, ringed like the unread dot so it sits on the avatar.
struct CallBadge: View {
    let conversation: Conversation
    var isSelected = false

    var body: some View {
        Image(systemName: conversation.isVideoCall ? "video.fill" : "phone.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(.green, in: .circle)
            .overlay {
                Circle().stroke(
                    isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .windowBackgroundColor),
                    lineWidth: 2
                )
            }
            .help("Call in progress")
            .accessibilityHidden(true)
    }
}

/// Under the conversation's name while a call is running in it: how long it has been going,
/// and the way in.
struct CallInProgressBar: View {
    let conversation: Conversation
    /// Joins here; nil while in another call, when the browser is the way in.
    var onJoin: (() -> Void)?
    var onJoinInBrowser: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CallSymbol(conversation: conversation, size: 13)
            HStack(spacing: 4) {
                Text(conversation.isVideoCall ? "Video call in progress" : "Call in progress")
                if let started = conversation.callStartTime {
                    Text("·").foregroundStyle(.secondary)
                    // Counts up on its own, so the bar doesn't have to be redrawn to stay true.
                    Text(started, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let onJoin {
                Button("Join", action: onJoin)
                    .buttonStyle(.link)
                    .help("Join the call")
            } else {
                Button("Join in Browser", action: onJoinInBrowser)
                    .buttonStyle(.link)
                    .help("You’re in another call; this opens the conversation in Nextcloud")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(.panel, cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }
}
