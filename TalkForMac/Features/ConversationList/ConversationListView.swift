import SwiftUI

/// The sidebar.
///
/// A `List` with `selection:` rather than a hand-rolled stack, so arrow-key navigation,
/// type-select, focus rings, right-click and the sidebar material are all the system's
/// behaviour rather than an imitation of it.
struct ConversationListView: View {
    @Bindable var model: ConversationListModel
    @Binding var selection: String?
    @Binding var composerFocused: Bool

    @FocusState private var isSearchFocused: Bool
    var searchFocusRequest: Bool
    var onSearchFocusHandled: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(model.conversations) { conversation in
                ConversationRow(conversation: conversation)
                    .tag(conversation.token)
                    .contextMenu { contextMenu(for: conversation) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.filterText, placement: .sidebar, prompt: "Search Conversations")
        .searchFocused($isSearchFocused)
        .overlay { emptyState }
        .onChange(of: searchFocusRequest) { _, requested in
            if requested {
                isSearchFocused = true
                onSearchFocusHandled()
            }
        }
        .onKeyPress(.return) {
            // Return from the sidebar moves you into the conversation you just picked.
            guard selection != nil else { return .ignored }
            composerFocused = true
            return .handled
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.conversations.isEmpty {
            if model.isFiltering {
                ContentUnavailableView.search(text: model.filterText)
            } else if model.isLoadingFirstTime {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Conversations you join in Nextcloud Talk appear here.")
                )
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for conversation: Conversation) -> some View {
        Button(conversation.isFavorite ? "Remove from Favourites" : "Add to Favourite") {
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

/// One row: avatar, name, one-line preview, timestamp, unread state.
///
/// Unread is a small dot and a bolder name, not a shouty pill — the sidebar should read as
/// calm at a glance and still make unread obvious.
struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(conversation: conversation, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if conversation.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(conversation.displayName)
                        .font(.system(size: 13, weight: conversation.hasUnread ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(timestamp)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                HStack(spacing: 4) {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(conversation.hasUnread ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 2)

                    if conversation.unreadMention {
                        Image(systemName: "at.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .help("You were mentioned")
                    } else if conversation.hasUnread {
                        unreadIndicator
                    }
                    if conversation.notificationLevel == .never {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var unreadIndicator: some View {
        if conversation.unreadMessages > 1 {
            Text("\(min(conversation.unreadMessages, 99))")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor, in: .capsule)
        } else {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
        }
    }

    private var preview: String { ConversationPreview.text(for: conversation) }

    private var timestamp: String { RelativeTimestamp.sidebar(conversation.lastActivity) }

    private var accessibilityLabel: String {
        var parts = [conversation.displayName]
        if conversation.unreadMessages > 0 { parts.append("\(conversation.unreadMessages) unread") }
        if conversation.unreadMention { parts.append("mentions you") }
        parts.append(preview)
        return parts.joined(separator: ", ")
    }
}
