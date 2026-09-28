import SwiftUI

/// One row of the compact sidebar: the face with the unread dot on it, and the name
/// beneath, cut to the column's width as Messages cuts it. The full name is the tooltip,
/// and what VoiceOver reads.
struct CompactConversationRow: View {
    let conversation: Conversation
    var isSelected = false

    var body: some View {
        VStack(spacing: 3) {
            AvatarView(conversation: conversation, size: SidebarMode.compactAvatarSize)
                .overlay(alignment: .topTrailing) {
                    if conversation.hasUnread {
                        UnreadDot(isSelected: isSelected)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if conversation.hasCall {
                        CallBadge(conversation: conversation, isSelected: isSelected)
                    }
                }
            Text(conversation.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: SidebarMode.compactRowHeight)
        .contentShape(.rect)
        .help(conversation.displayName)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [conversation.displayName]
        if conversation.unreadMessages > 0 { parts.append(String(localized: "\(conversation.unreadMessages) unread", comment: "Unread message count")) }
        if conversation.unreadMention { parts.append(String(localized: "mentions you", comment: "Accessibility: a conversation has an unread @-mention of you")) }
        if conversation.hasCall { parts.append(String(localized: "call in progress", comment: "Accessibility: a conversation has a call going on")) }
        return parts.joined(separator: ", ")
    }
}
