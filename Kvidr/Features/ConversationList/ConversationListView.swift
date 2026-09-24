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
    /// Upcoming reminders; the Reminders row shows while there are any.
    var reminderCount = 0
    /// Conversations with something unread; the Catch Up row shows from two on.
    var catchUpCount = 0

    @FocusState private var isSearchFocused: Bool
    @State private var deletingTag: ConversationTag?
    /// The row whose menu is open, for its outline.
    @State private var menuToken: String?

    init(
        model: ConversationListModel,
        selection: Binding<String?>,
        composerFocused: Binding<Bool>,
        searchFocusRequest: Bool,
        onSearchFocusHandled: @escaping () -> Void,
        draft: ConversationDraft? = nil,
        onDiscardDraft: @escaping () -> Void = {},
        reminderCount: Int = 0,
        catchUpCount: Int = 0
    ) {
        self.model = model
        _selection = selection
        _composerFocused = composerFocused
        self.searchFocusRequest = searchFocusRequest
        self.onSearchFocusHandled = onSearchFocusHandled
        self.draft = draft
        self.onDiscardDraft = onDiscardDraft
        self.reminderCount = reminderCount
        self.catchUpCount = catchUpCount
    }

    var body: some View {
        List(selection: $selection) {
            if catchUpCount >= 2, !model.isFiltering {
                CatchUpSidebarRow(count: catchUpCount)
                    .tag(CatchUpToken.value)
                    .listRowSeparator(.hidden)
            }
            if reminderCount > 0, !model.isFiltering {
                RemindersSidebarRow(count: reminderCount)
                    .tag(RemindersToken.value)
                    .listRowSeparator(.hidden)
            }

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

                // The user's own groups — Talk's tags — each under its name, and folding.
                case .tagged where !model.isFiltering:
                    if let tag = group.tag {
                        Section {
                            rows(shown(group))
                        } header: {
                            TagSectionHeader(title: group.title, isCollapsed: tag.isCollapsed, hidden: group.items.count - shown(group).count) {
                                model.setCollapsed(tag, !tag.isCollapsed)
                            }
                            .contextMenu { tagMenu(tag) }
                        }
                    }

                // Everything untagged, under Talk's name for it — a heading only once there are
                // tags above it to be told apart from.
                case .conversations where !model.isFiltering && hasTagSections:
                    Section {
                        rows(shown(group))
                    } header: {
                        if let tag = group.tag {
                            TagSectionHeader(title: group.title, isCollapsed: tag.isCollapsed, hidden: group.items.count - shown(group).count) {
                                model.setCollapsed(tag, !tag.isCollapsed)
                            }
                        } else {
                            TagSectionHeader(title: group.title, isCollapsed: false, hidden: 0, onToggle: nil)
                        }
                    }

                default:
                    rows(group.items)
                }
            }
        }
        .listStyle(.sidebar)
        .alert(model.namingTag?.title ?? "", isPresented: Binding(get: { model.namingTag != nil }, set: { isShown in
            // Later, not now: the alert closes before its button's action runs, and Create
            // still needs the name.
            if !isShown { Task { @MainActor in model.namingTag = nil } }
        })) {
            TextField("Name", text: Binding(get: { model.namingTag?.name ?? "" }, set: { model.namingTag?.name = $0 }))
            Button(model.namingTag.map { if case .rename = $0.purpose { "Rename" } else { "Create" } } ?? "OK") { model.finishNaming() }
            Button("Cancel", role: .cancel) { model.namingTag = nil }
        }
        .confirmationDialog("Delete the tag “\(deletingTag?.name ?? "")”?", isPresented: Binding(get: { deletingTag != nil }, set: { isShown in
            // Later, for the same reason: Delete Tag still needs to know which.
            if !isShown { Task { @MainActor in deletingTag = nil } }
        })) {
            Button("Delete Tag", role: .destructive) {
                if let deletingTag { model.deleteTag(deletingTag) }
                deletingTag = nil
            }
            Button("Cancel", role: .cancel) { deletingTag = nil }
        } message: {
            Text("Its conversations stay, and go back among the rest.")
        }
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

    private var hasTagSections: Bool {
        model.sections.contains { $0.section == .tagged }
    }

    /// A folded section still shows what needs you: the unread, the ones with a call on, and
    /// the one that's open — as Talk's web app folds them.
    private func shown(_ group: ConversationIndex.SectionGroup) -> [Conversation] {
        guard group.tag?.isCollapsed == true else { return group.items }
        return group.items.filter { $0.token == selection || $0.unreadMessages > 0 || $0.hasCall }
    }

    @ViewBuilder
    private func tagMenu(_ tag: ConversationTag) -> some View {
        let custom = model.customTags
        Button("Rename…") { model.beginRenaming(tag) }
        Button("Move Up") { model.moveTag(tag, by: -1) }
            .disabled(custom.first == tag)
        Button("Move Down") { model.moveTag(tag, by: 1) }
            .disabled(custom.last == tag)
        Divider()
        Button("New Tag…") { model.beginNewTag(for: nil) }
        Divider()
        Button("Delete Tag…", role: .destructive) { deletingTag = tag }
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
                .modifier(ConversationRowMenu(model: model, token: conversation.token, menuToken: $menuToken))
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
    /// The face being carried, and where. Kept out of this view's own state: this view is a
    /// row of the list, and a change to its state has the list rebuild the row — every face
    /// then starts over where it is now, and nothing slides. Only the faces read it.
    @State private var drag = FaceDrag()
    @State private var gridSize: CGSize = .zero

    private static let space = "favouriteFaces"
    private static let minimumCellWidth: CGFloat = 72
    private static let spacing: CGFloat = 2

    /// Three across at the sidebar's ideal width, as in Messages.
    private let columns = [GridItem(.adaptive(minimum: minimumCellWidth), spacing: spacing)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(conversations) { conversation in
                let isSelected = selection == conversation.token
                Button {
                    guard !drag.didDrag else { drag.didDrag = false; return }
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
                // The face itself is carried — its picture and its name, not a snapshot of
                // them — and the others slide aside to make room, the way Messages
                // rearranges its pinned faces. Not system drag and drop: that lights up the
                // list row the grid sits in, and puts down a second copy of the face while
                // its drag image is still on the way back.
                .modifier(CarriedFace(drag: drag, token: conversation.token, grid: grid))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                        .onChanged { carry(conversation.token, value: $0) }
                        .onEnded { _ in putDown() }
                )
                .help(conversation.displayName)
                .accessibilityLabel(label(for: conversation))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { gridSize = $0 }
        // Out past the list's own content inset, so the selected block lands level with a
        // selected row's highlight. Measured on macOS 26.6: a row's content starts 16pt
        // from the sidebar's edge and its highlight 10pt, so the grid reaches out by 6.
        .padding(.horizontal, -6)
        .padding(.vertical, 6)
    }

    private var grid: FaceGrid {
        FaceGrid(size: gridSize, count: conversations.count, minimumCellWidth: Self.minimumCellWidth, spacing: Self.spacing)
    }

    // MARK: - Rearranging

    private func carry(_ token: String, value: DragGesture.Value) {
        guard !drag.settling else { return }
        let grid = grid
        if drag.token != token {
            let order = conversations.map(\.token)
            drag.base = order
            drag.order = order
            drag.startSlot = order.firstIndex(of: token) ?? 0
            drag.token = token
            drag.didDrag = true
        }
        drag.translation = value.translation
        let start = grid.origin(ofSlot: drag.startSlot)
        let center = CGPoint(
            x: start.x + grid.cell.width / 2 + value.translation.width,
            y: start.y + grid.cell.height / 2 + value.translation.height
        )
        guard let target = grid.slot(at: center), let from = drag.order.firstIndex(of: token), from != target else { return }
        var order = drag.order
        order.remove(at: from)
        order.insert(token, at: min(target, order.count))
        withAnimation(FaceDrag.slide) { drag.order = order }
    }

    /// Let go: the face glides from the pointer into its place — the one face, not a copy on
    /// its way back while the real one appears — and then the grid takes the new order.
    private func putDown() {
        guard let token = drag.token, !drag.settling else { return }
        let grid = grid
        let index = drag.order.firstIndex(of: token) ?? drag.startSlot
        let start = grid.origin(ofSlot: drag.startSlot)
        let place = grid.origin(ofSlot: index)
        withAnimation(FaceDrag.land) {
            drag.settling = true
            drag.translation = CGSize(width: place.x - start.x, height: place.y - start.y)
        } completion: {
            // The new order and the offsets' end in the same frame, so nothing on screen moves.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.setFavoriteOrder(drag.order)
                drag.token = nil
                drag.translation = .zero
                drag.settling = false
            }
        }
        // Released off every face, no click comes to clear the flag; clear it after this event.
        Task { @MainActor in drag.didDrag = false }
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
        if conversation.hasUnread { parts.append(String(localized: "\(conversation.unreadMessages) unread", comment: "Unread message count")) }
        if conversation.hasCall { parts.append(String(localized: "call in progress", comment: "Accessibility: a conversation has a call going on")) }
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
        // Uneven on purpose. The line box of the 15pt name starts well above its capitals and
        // the preview's ends close under its descenders, so even padding left the separator
        // about 9pt under one row's text and 17pt over the next's. These put it halfway —
        // about 15pt each way, measured on the rendered rows — as Messages spaces its list.
        .padding(.top, 5)
        .padding(.bottom, 13)
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
        if conversation.unreadMessages > 0 { parts.append(String(localized: "\(conversation.unreadMessages) unread", comment: "Unread message count")) }
        if conversation.unreadMention { parts.append(String(localized: "mentions you", comment: "Accessibility: a conversation has an unread @-mention of you")) }
        if conversation.hasCall { parts.append(String(localized: "call in progress", comment: "Accessibility: a conversation has a call going on")) }
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
        .padding(.top, 5)
        .padding(.bottom, 13)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

/// A favourite being carried in the grid of faces.
@MainActor
@Observable
private final class FaceDrag {
    static let slide = Animation.smooth(duration: 0.3)
    static let land = Animation.smooth(duration: 0.32)

    var token: String?
    /// The order when it was picked up — the grid's order until it is put down.
    var base: [String] = []
    /// The order on screen: the others slide aside as it passes.
    var order: [String] = []
    var startSlot = 0
    /// How far the pointer has moved since it was picked up.
    var translation: CGSize = .zero
    /// Put down and gliding into its place.
    var settling = false
    /// Set by a drag so the click that ends it doesn't also open the conversation.
    var didDrag = false
}

/// The slots of the grid of faces: columns as `.adaptive(minimum:)` lays them out, rows of
/// equal height.
private struct FaceGrid: Equatable {
    let size: CGSize
    let count: Int
    let minimumCellWidth: CGFloat
    let spacing: CGFloat

    private var columns: Int { max(1, Int((size.width + spacing) / (minimumCellWidth + spacing))) }
    private var rows: Int { max(1, Int(ceil(Double(count) / Double(columns)))) }

    var cell: CGSize {
        CGSize(
            width: (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns),
            height: (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        )
    }

    /// The slot at a point; anything past the last face — the empty end of the last row —
    /// is the last slot.
    ///
    /// Over another face, the carried one has to reach the middle half of it first, so the
    /// face making room slides out from under it rather than staying hidden beneath it.
    func slot(at point: CGPoint) -> Int? {
        guard count > 0, size.width > 0, size.height > 0 else { return nil }
        let stride = cell.width + spacing
        let column = min(columns - 1, max(0, Int(point.x / stride)))
        let row = min(rows - 1, max(0, Int(point.y / (cell.height + spacing))))
        let slot = row * columns + column
        guard slot < count else { return count - 1 }
        let fromMiddle = abs(point.x - (CGFloat(column) * stride + cell.width / 2))
        return fromMiddle <= cell.width / 4 ? slot : nil
    }

    func origin(ofSlot slot: Int) -> CGPoint {
        guard size.width > 0 else { return .zero }
        return CGPoint(
            x: CGFloat(slot % columns) * (cell.width + spacing),
            y: CGFloat(slot / columns) * (cell.height + spacing)
        )
    }
}

/// How a face looks while a favourite is carried. The carried one is lifted and follows the
/// pointer; the others are drawn offset from their places in the grid to their places in the
/// new order, which the grid only takes when the face is put down.
private struct CarriedFace: ViewModifier {
    let drag: FaceDrag
    let token: String
    let grid: FaceGrid

    func body(content: Content) -> some View {
        let isCarried = drag.token == token
        let isLifted = isCarried && !drag.settling
        content
            .scaleEffect(isLifted ? 1.08 : 1)
            .shadow(color: .black.opacity(isLifted ? 0.18 : 0), radius: 8, y: 4)
            .animation(.smooth(duration: 0.26), value: isLifted)
            .offset(isCarried ? drag.translation : shift)
            .zIndex(isCarried ? 1 : 0)
            // The carried face follows the pointer, not the slide.
            .transaction { if isLifted { $0.animation = nil } }
    }

    private var shift: CGSize {
        guard drag.token != nil,
              let base = drag.base.firstIndex(of: token),
              let now = drag.order.firstIndex(of: token)
        else { return .zero }
        let from = grid.origin(ofSlot: base)
        let to = grid.origin(ofSlot: now)
        return CGSize(width: to.x - from.x, height: to.y - from.y)
    }
}

/// A tag's heading in the sidebar: its name, a chevron to fold it by, and — folded — how many
/// conversations are tucked away.
private struct TagSectionHeader: View {
    let title: String
    let isCollapsed: Bool
    /// Conversations folded out of sight.
    let hidden: Int
    /// Nil where the section doesn't fold.
    var onToggle: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Text(isCollapsed && hidden > 0 ? "\(title) (\(hidden))" : title)
                // As the Archived heading: a row's timestamp size, at the selection's edge.
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if onToggle != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isCollapsed)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, -3)
        .contentShape(.rect)
        .onTapGesture { onToggle?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onToggle == nil ? [.isHeader] : [.isHeader, .isButton])
        .accessibilityHint(onToggle == nil ? "" : (isCollapsed ? "Unfold" : "Fold"))
    }
}
