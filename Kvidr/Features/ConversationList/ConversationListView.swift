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

    var searchFocusRequest: Bool
    var onSearchFocusHandled: () -> Void

    @FocusState private var isSearchFocused: Bool

    init(
        model: ConversationListModel,
        selection: Binding<String?>,
        composerFocused: Binding<Bool>,
        searchFocusRequest: Bool,
        onSearchFocusHandled: @escaping () -> Void
    ) {
        self.model = model
        _selection = selection
        _composerFocused = composerFocused
        self.searchFocusRequest = searchFocusRequest
        self.onSearchFocusHandled = onSearchFocusHandled
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(model.sections) { group in
                if model.showsSectionHeadings {
                    Section {
                        rows(group.items)
                    } header: {
                        Label(group.section.title, systemImage: group.section.symbolName)
                            .font(.caption)
                    }
                } else {
                    rows(group.items)
                }
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
    private func rows(_ conversations: [Conversation]) -> some View {
        ForEach(conversations) { conversation in
            // No tap gesture of any kind here, deliberately. A SwiftUI tap recogniser on
            // a List row consumes the mouse event before the table underneath can act on
            // it, so selection stops responding to a single click — and `simultaneous`
            // does not help, because the simultaneity is with other SwiftUI gestures,
            // not with the List's own handling. Selection is the List's job; Return from
            // the sidebar (below) is what moves focus on to the composer.
            ConversationRow(conversation: conversation)
                .tag(conversation.token)
                .contextMenu { contextMenu(for: conversation) }
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
            AvatarView(conversation: conversation, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if conversation.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(conversation.displayName)
                        .font(.system(size: 14, weight: conversation.hasUnread ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(timestamp)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                HStack(alignment: .top, spacing: 4) {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(conversation.hasUnread ? .secondary : .tertiary)
                        // Two lines, like Messages: one line of preview is rarely enough
                        // to tell two conversations apart at a glance.
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)

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
        .padding(.vertical, 6)
        // Without this, only the drawn glyphs are hit-testable: the gaps the Spacers open
        // up between name, timestamp and preview swallow clicks, and the row reads as
        // having dead patches in it.
        .contentShape(.rect)
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
