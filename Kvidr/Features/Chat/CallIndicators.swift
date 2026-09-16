import AppKit
import SwiftUI

/// Calls happen in the browser for now: kvidr doesn't speak Talk's signaling, so what it can
/// do is say that a call is running and hand you to the page where you join it. The web
/// conversation page is that page — its Join Call button is the first thing on it.

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
    var onJoin: () -> Void

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
            Button("Join in Browser", action: onJoin)
                .buttonStyle(.link)
                .help("Opens this conversation in Nextcloud, where you can join the call")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(.panel, cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }
}
