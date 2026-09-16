import SwiftUI

/// The right-click menu on a conversation, the same in both widths of the sidebar.
struct ConversationContextMenu: View {
    let model: ConversationListModel
    let conversation: Conversation

    var body: some View {
        if conversation.hasCall {
            Button("Join Call in Browser") { model.openInBrowser(conversation) }
            Divider()
        }

        Button(conversation.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            model.toggleFavorite(conversation)
        }

        if model.hasMarkUnread {
            Button("Mark as Unread") { model.markUnread(conversation) }
                .disabled(conversation.unreadMessages > 0)
        }

        Divider()

        Menu("Notifications") {
            ForEach(NotificationLevel.allCases) { level in
                Button {
                    model.setNotificationLevel(level, for: conversation)
                } label: {
                    if conversation.notificationLevel == level {
                        Label(level.title, systemImage: "checkmark")
                    } else {
                        Text(level.title)
                    }
                }
            }
        }

        Divider()

        Button("Copy Link") { model.copyLink(to: conversation) }
        Button("Open in Nextcloud") { model.openInBrowser(conversation) }
    }
}
