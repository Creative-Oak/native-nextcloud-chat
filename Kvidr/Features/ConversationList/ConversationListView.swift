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
    var draft: ConversationDraft?
    var onDiscardDraft: () -> Void

    @FocusState private var isSearchFocused: Bool

    init(
        model: ConversationListModel,
        selection: Binding<String?>,
        composerFocused: Binding<Bool>,
        searchFocusRequest: Bool,
        onSearchFocusHandled: @escaping () -> Void,
        draft: ConversationDraft? = nil,
        onDiscardDraft: @escaping () -> Void = {}
    ) {
        self.model = model
        _selection = selection
        _composerFocused = composerFocused
        self.searchFocusRequest = searchFocusRequest
        self.onSearchFocusHandled = onSearchFocusHandled
        self.draft = draft
        self.onDiscardDraft = onDiscardDraft
    }

    var body: some View {
        List(selection: $selection) {
            // Under the pinned faces rather than over them, where Messages puts it — the
            // faces are the top of the sidebar and a draft does not displace them. When
            // there are none to sit under, it goes first instead.
            if !hasPinnedFaces { draftRow }

            ForEach(model.sections) { group in
                switch group.section {
                // Favourites become the grid of faces at the top, the way Messages pins
                // conversations. Talk's "favourite" already means exactly this, so it is
                // a different presentation of an existing idea rather than a new one.
                // While filtering, everything is one flat list of results.
                case .favorites where !model.isFiltering:
                    PinnedConversations(model: model, conversations: group.items, selection: $selection)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    draftRow

                // The only heading. Messages has none, and "Conversations" over the
                // conversations said nothing; archived ones are the one group that
                // needs to be told apart from the rest.
                //
                // It folds, closed to begin with, and says how much is in it while closed.
                case .archived where !model.isFiltering:
                    Section(isExpanded: $model.isArchiveExpanded) {
                        rows(group.items)
                    } header: {
                        Text(model.isArchiveExpanded ? group.section.title : "\(group.section.title) (\(group.items.count))")
                            // The size of a row's timestamp. The list sets its headings 13pt
                            // in from the sidebar's edge (measured, macOS 26.6); pulled out
                            // to the 10pt the selection highlight keeps.
                            .font(.system(size: 12))
                            .padding(.leading, -3)
                    }

                default:
                    rows(group.items)
                }
            }
        }
        .listStyle(.sidebar)
        // The search field as Messages draws it: a rounded pane at the top of the
        // sidebar. `.searchable` on this list gives the toolbar's small field, which
        // cannot be restyled.
        .safeAreaInset(edge: .top, spacing: 0) {
            // 10pt in from each side, the margin the selection highlight keeps.
            SidebarSearchField(text: $model.filterText, isFocused: $isSearchFocused)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
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

    /// Whether the grid of faces is on screen for the draft to sit beneath.
    private var hasPinnedFaces: Bool {
        !model.isFiltering && model.sections.contains { $0.section == .favorites }
    }

    @ViewBuilder
    private var draftRow: some View {
        if let draft {
            DraftRow(
                draft: draft,
                onDiscard: onDiscardDraft,
                isSelected: ConversationDraftToken.isDraft(selection)
            )
                .tag(ConversationDraftToken.value)
                .listRowSeparator(.hidden)
        }
    }

    private func rows(_ conversations: [Conversation]) -> some View {
        ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
            // A row draws its separator at its own bottom, so the one that would land in the
            // gap above a selected row belongs to the row before it — which has to be told.
            let precedesSelection = conversations.indices.contains(index + 1)
                && selection == conversations[index + 1].token

            // No tap gesture of any kind here, deliberately. A SwiftUI tap recogniser on
            // a List row consumes the mouse event before the table underneath can act on
            // it, so selection stops responding to a single click — and `simultaneous`
            // does not help, because the simultaneity is with other SwiftUI gestures,
            // not with the List's own handling. Selection is the List's job; Return from
            // the sidebar (below) is what moves focus on to the composer.
            ConversationRow(
                conversation: conversation,
                isSelected: selection == conversation.token,
                precedesSelection: precedesSelection
            )
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

/// The sidebar's search field, drawn as Messages draws it: a glass capsule with a
/// magnifier, the prompt, and a clear button once there is something to clear. Escape
/// empties it and gives up focus.
private struct SidebarSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text, prompt: Text("Search"))
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onExitCommand {
                    text = ""
                    isFocused.wrappedValue = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glass(.field, cornerRadius: 15)
    }
}

/// The pinned favourites, as a grid of faces above the list.
///
/// Plain `Button`s rather than List rows: these aren't selectable rows, they're controls
/// that set the selection — and a tap recogniser on an actual row would fight the List for
/// the click, which is a mistake this file has made before.
private struct PinnedConversations: View {
    let model: ConversationListModel
    let conversations: [Conversation]
    @Binding var selection: String?
    /// The face whose menu is open.
    @State private var menuToken: String?

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
                            .overlay(alignment: .bottomTrailing) {
                                if conversation.hasCall {
                                    CallBadge(conversation: conversation, isSelected: isSelected)
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
                // An outline around this face while its menu is open, where a list row
                // would draw one around itself.
                .overlay {
                    if menuToken == conversation.token {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .overlay {
                    ConversationMenuHost(
                        model: model,
                        token: conversation.token,
                        isOpen: Binding(
                            get: { menuToken == conversation.token },
                            set: { menuToken = $0 ? conversation.token : nil }
                        )
                    )
                }
                .help(conversation.displayName)
                .accessibilityLabel(label(for: conversation))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        // Out past the list's own content inset, so the selected block lands level with a
        // selected row's highlight. Measured on macOS 26.6: a row's content starts 16pt
        // from the sidebar's edge and its highlight 10pt, so the grid reaches out by 6.
        .padding(.horizontal, -6)
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
        var parts = [conversation.displayName]
        if conversation.hasUnread { parts.append("\(conversation.unreadMessages) unread") }
        if conversation.hasCall { parts.append("call in progress") }
        return parts.joined(separator: ", ")
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
    /// The row below this one is the selected one, so this row's separator would be drawn in
    /// the gap above its highlight.
    var precedesSelection = false

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

                        if conversation.hasCall {
                            CallSymbol(conversation: conversation, size: 11)
                        }

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
            // Neither under a selected row nor over one: a separator resting against the
            // highlight reads as a line drawn on it.
            if !isSelected && !precedesSelection {
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
        if conversation.hasCall { parts.append("call in progress") }
        parts.append(preview)
        return parts.joined(separator: ", ")
    }
}

/// The unsent conversation's row.
///
/// Built to `ConversationRow`'s measurements rather than its own — the same gutter, the same
/// 40pt avatar, the same text inset and weight — so it sits in the list as a conversation
/// that happens to have no messages yet, rather than as a banner stuck above one. What it
/// drops is the preview line and the timestamp, because it has neither.
///
/// Its × throws away a local object: nothing has reached the server, so there is nothing to
/// confirm and nothing to undo.
private struct DraftRow: View {
    @Bindable var draft: ConversationDraft
    var onDiscard: () -> Void
    var isSelected = false

    @State private var isHovering = false

    private static let gutter: CGFloat = 8
    private static let avatar: CGFloat = 40

    var body: some View {
        HStack(spacing: 5) {
            // The unread gutter, empty: it is what lines the avatar up with every other row.
            Color.clear
                .frame(width: Self.gutter, height: Self.gutter)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.avatar, height: Self.avatar)
                    .background(.quaternary.opacity(0.5), in: .circle)

                Text(draft.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button(action: onDiscard) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .opacity(isHovering ? 1 : 0)
                .help("Discard this message")
                .accessibilityLabel("Discard this message")
            }
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}
