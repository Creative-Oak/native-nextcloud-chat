import SwiftUI

/// In place of the conversation while you're held in its lobby: whose it is, that you're
/// waiting, and — when a moderator set one — when it opens. The conversation comes in by
/// itself as soon as it does.
struct LobbyWaitingView: View {
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            AvatarView(conversation: conversation, size: 88)
            VStack(spacing: 6) {
                Text("You’re in the lobby")
                    .font(.title2.weight(.semibold))
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let opens = conversation.lobbyTimer, opens > .now {
                Label {
                    Text("Opens \(Text(opens, style: .relative)) · \(opens.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glass(.panel, cornerRadius: 14)
            }
            if !conversation.description.isEmpty {
                Text(conversation.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)
                .accessibilityLabel("Waiting for the lobby to open")
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var explanation: String {
        if conversation.isBreakoutRoom {
            return "\(conversation.displayName) is a breakout room. It opens when a moderator starts the breakout rooms, and you’ll be taken in then."
        }
        if conversation.lobbyTimer.map({ $0 > .now }) == true {
            return "Only moderators can see \(conversation.displayName) until it opens. You’ll be taken in as soon as it does."
        }
        return "Only moderators can see \(conversation.displayName) until one of them opens it. You’ll be taken in as soon as they do."
    }
}

/// Over a conversation whose lobby is on, for its moderators: everyone else is waiting, until
/// when, and the way to let them in now.
struct LobbyBar: View {
    let opensAt: Date?
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "door.left.hand.closed")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(text)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button("Open Now", action: onOpen)
                .buttonStyle(.link)
                .fixedSize()
                .help("Turn the lobby off, and let everyone in")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 460, alignment: .leading)
        .glass(.panel, cornerRadius: 10)
    }

    private var text: String {
        guard let opensAt, opensAt > .now else { return "Lobby is on — only moderators can see this conversation" }
        return "Lobby is on — opens \(opensAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
