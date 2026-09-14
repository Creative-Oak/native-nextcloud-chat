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
                switch group.section {
                // Favourites become the grid of faces at the top, the way Messages pins
                // conversations. Talk's "favourite" already means exactly this, so it is
                // a different presentation of an existing idea rather than a new one.
                // While filtering, everything is one flat list of results.
                case .favorites where !model.isFiltering:
                    PinnedConversations(conversations: group.items, selection: $selection)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                // The only heading. Messages has none, and "Conversations" over the
                // conversations said nothing; archived ones are the one group that
                // needs to be told apart from the rest.
                case .archived where !model.isFiltering:
                    Section {
                        rows(group.items)
                    } header: {
                        Text(group.section.title)
                            .font(.caption)
                    }

                default:
                    rows(group.items)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.filterText, placement: .sidebar, prompt: "Search Conversations")
        .searchFocused($isSearchFocused)
        .overlay { emptyState }
        // `initial:` because ⌘F from the compact sidebar creates this list with the
        // request already set — a change-only observer would never see it.
        .onChange(of: searchFocusRequest, initial: true) { _, requested in
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
            ConversationRow(conversation: conversation, isSelected: selection == conversation.token)
                .tag(conversation.token)
                .contextMenu { ConversationContextMenu(model: model, conversation: conversation) }
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

}

/// The pinned favourites, as a grid of faces above the list.
///
/// Plain `Button`s rather than List rows: these aren't selectable rows, they're controls
/// that set the selection — and a tap recogniser on an actual row would fight the List for
/// the click, which is a mistake this file has made before.
private struct PinnedConversations: View {
    let conversations: [Conversation]
    @Binding var selection: String?

    /// Three across at the sidebar's ideal width, as in Messages.
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 2)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(conversations) { conversation in
                let isSelected = selection == conversation.token
                Button {
                    selection = conversation.token
                } label: {
                    VStack(spacing: 6) {
                        AvatarView(conversation: conversation, size: 62)
                            .overlay(alignment: .topTrailing) {
                                if conversation.hasUnread {
                                    UnreadDot(isSelected: isSelected)
                                }
                            }
                        Text(Self.title(for: conversation))
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                    // The selected face sits on a solid block of the same blue a selected
                    // sidebar row gets — one selection look, not two. That is the
                    // system's selection colour, which is a shade deeper than the accent.
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .selectedContentBackgroundColor))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(conversation.displayName)
                .accessibilityLabel(label(for: conversation))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        // Out past the list's own content inset, so the faces sit a little nearer the
        // sidebar's edge than the rows' avatars do and the selected block lands level
        // with a selected row's highlight — which is how Messages sets its grid.
        .padding(.horizontal, -10)
        .padding(.vertical, 6)
    }

    /// A person's first name, a group's whole name. The cells are narrow, and
    /// "Heine Volder R…" says less than "Heine" does.
    private static func title(for conversation: Conversation) -> String {
        guard conversation.isOneToOne,
              let first = conversation.displayName.split(separator: " ", omittingEmptySubsequences: true).first
        else { return conversation.displayName }
        return String(first)
    }

    private func label(for conversation: Conversation) -> String {
        conversation.hasUnread
            ? "\(conversation.displayName), \(conversation.unreadMessages) unread"
            : conversation.displayName
    }
}

/// One row: unread dot in the gutter, avatar, name, timestamp, two lines of preview.
///
/// Laid out the way Messages lays its rows out, so the sidebar reads as calm at a glance
/// and still makes unread obvious: the dot sits in the gutter before the avatar, the name
/// gets a shade heavier, and nothing else changes.
struct ConversationRow: View {
    let conversation: Conversation
    var isSelected = false

    /// The gutter the unread dot lives in, plus the avatar and the gap after it — the
    /// separator between rows starts where the text does, as it does in Messages.
    private static let gutter: CGFloat = 8
    private static let avatar: CGFloat = 40
    private static let textInset: CGFloat = gutter + 5 + avatar + 10

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(conversation.hasUnread ? Color.accentColor : .clear)
                .frame(width: Self.gutter, height: Self.gutter)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                AvatarView(conversation: conversation, size: Self.avatar)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(conversation.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        Text(timestamp)
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .fixedSize()
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text(preview)
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            // Two lines, always: Messages keeps every row the same
                            // height, and a list whose rows are all different heights
                            // reads as a jumble.
                            .lineLimit(2, reservesSpace: true)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 2)

                        if conversation.unreadMention {
                            Image(systemName: "at.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(isSelected ? .white : Color.accentColor)
                                .help("You were mentioned")
                        } else if conversation.unreadMessages > 1 {
                            unreadCount
                        }
                        if conversation.notificationLevel == .never {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 7)
        // Without this, only the drawn glyphs are hit-testable: the gaps the Spacers open
        // up between name, timestamp and preview swallow clicks, and the row reads as
        // having dead patches in it.
        .contentShape(.rect)
        // The sidebar list draws no separators of its own. This one starts under the
        // text, not the avatar, and stands down while the row is highlighted.
        .overlay(alignment: .bottom) {
            if !isSelected {
                Divider().padding(.leading, Self.textInset)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var unreadCount: some View {
        Text("\(min(conversation.unreadMessages, 99))")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(isSelected ? Color.white : Color.accentColor, in: .capsule)
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
