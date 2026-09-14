import SwiftUI

/// One row of the compact sidebar: the face, and the unread dot on it. The name is the
/// tooltip, and what VoiceOver reads.
struct CompactConversationRow: View {
    let conversation: Conversation
    var isSelected = false

    var body: some View {
        AvatarView(conversation: conversation, size: SidebarMode.compactAvatarSize)
            .overlay(alignment: .topTrailing) {
                if conversation.hasUnread {
                    UnreadDot(isSelected: isSelected)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .help(conversation.displayName)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [conversation.displayName]
        if conversation.unreadMessages > 0 { parts.append("\(conversation.unreadMessages) unread") }
        if conversation.unreadMention { parts.append("mentions you") }
        return parts.joined(separator: ", ")
    }
}
