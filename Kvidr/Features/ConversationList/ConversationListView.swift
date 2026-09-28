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

    @FocusState private var isSearchFocused: Bool

    init(
        model: ConversationListModel,
        selection: Binding<String?>,
        composerFocused: Binding<Bool>,
        searchFocusRequest: Bool,
        onSearchFocusHandled: @escaping () -> Void,
        draft: ConversationDraft? = nil,
        onDiscardDraft: @escaping () -> Void = {},
        reminderCount: Int = 0
    ) {
        self.model = model
        _selection = selection
        _composerFocused = composerFocused
        self.searchFocusRequest = searchFocusRequest
        self.onSearchFocusHandled = onSearchFocusHandled
        self.draft = draft
        self.onDiscardDraft = onDiscardDraft
        self.reminderCount = reminderCount
    }

    var body: some View {
        List(selection: $selection) {
            if reminderCount > 0, !model.isFiltering {
                RemindersSidebarRow(count: reminderCount, isSelected: RemindersToken.isReminders(selection))
                    .tag(RemindersToken.value)
                    .listRowSeparator(.hidden)
                    .phoneRowInsets()
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
                        #if os(iOS)
                        // A plain list's section header folds nothing on iOS by itself.
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { model.isArchiveExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(model.isArchiveExpanded ? group.section.title : "\(group.section.title) (\(group.items.count))")
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 13, weight: .semibold))
                                    .rotationEffect(.degrees(model.isArchiveExpanded ? 90 : 0))
                            }
                            .font(.scaled(12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        #else
                        Text(model.isArchiveExpanded ? group.section.title : "\(group.section.title) (\(group.items.count))")
                            // The size of a row's timestamp. The list sets its headings 13pt
                            // in from the sidebar's edge (measured, macOS 26.6); pulled out
                            // to the 10pt the selection highlight keeps.
                            .font(.scaled(12))
                            .padding(.leading, -3)
                        #endif
                    }

                default:
                    rows(group.items)
                }
            }
        }
        #if os(macOS)
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
        #else
        // Edge to edge, as Messages' list is on iPhone and iPad; the search field is the
        // system's, at the foot of the screen — see `SidebarColumn`.
        .listStyle(.plain)
        #endif
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
                .phoneRowInsets()
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
                // The row draws its own separator, starting under the text.
                .listRowSeparator(.hidden)
                .phoneRowInsets()
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
                .onEscape {
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
    /// Three across on iPhone too, as Messages pins them — bigger faces for fingers.
    private static let minimumCellWidth: CGFloat = Platform.isPhone ? 104 : 72
    private static let faceSize: CGFloat = Platform.isPhone ? 92 : 62
    private static let spacing: CGFloat = 2

    /// Three across at the sidebar's ideal width, as in Messages.
    private let columns = Platform.isPhone
        // Three across, the outer two against the list's edges and the middle one centred —
        // so the faces line up with the rows' avatars on the left and their chevrons on the
        // right, as Messages' pinned faces do.
        ? [GridItem(.flexible(), spacing: spacing, alignment: .leading),
           GridItem(.flexible(), spacing: spacing, alignment: .center),
           GridItem(.flexible(), spacing: spacing, alignment: .trailing)]
        : [GridItem(.adaptive(minimum: minimumCellWidth), spacing: spacing)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(conversations) { conversation in
                let isSelected = selection == conversation.token
                Group {
                    #if os(iOS)
                    // A menu of its own per face, opened by pressing and holding, with a tap
                    // still opening the conversation. Not `.contextMenu`: the faces share
                    // one list row, and a row gets one context menu — every face lifted the
                    // first face and acted on it.
                    // The picture alone is the menu's button: closing, the menu morphs back
                    // into its button clipped to the button's frame, and a name wider than
                    // the face ("Server Monitoring") came back as "erver Monitorin".
                    VStack(spacing: 6) {
                        Menu {
                            ConversationContextMenu(model: model, conversation: conversation)
                                // Holding a face to open its menu starts a carry too, and the
                                // menu cancels it without an end — which left the face lifted
                                // in spirit and the next tap swallowed as the end of a drag.
                                .onAppear { cancelCarry() }
                        } label: {
                            facePicture(conversation, isSelected: isSelected)
                        } primaryAction: {
                            guard !drag.didDrag else { drag.didDrag = false; return }
                            selection = conversation.token
                        }
                        faceName(conversation, isSelected: isSelected)
                            .onTapGesture { selection = conversation.token }
                    }
                    .frame(width: Self.faceSize)
                    .padding(.vertical, 8)
                    #else
                    Button {
                        guard !drag.didDrag else { drag.didDrag = false; return }
                        selection = conversation.token
                    } label: {
                        faceLabel(conversation, isSelected: isSelected)
                    }
                    #endif
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
                #if os(macOS)
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
                #endif
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
        // On a phone: the same margin as the rows' avatars on the left and their chevrons on
        // the right.
        .padding(.horizontal, Platform.isPhone ? ConversationRow.phoneMargin : -6)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func faceLabel(_ conversation: Conversation, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            facePicture(conversation, isSelected: isSelected)
            faceName(conversation, isSelected: isSelected)
        }
        .frame(width: Platform.isPhone ? Self.faceSize : nil)
        .frame(maxWidth: Platform.isPhone ? nil : .infinity)
        .padding(.vertical, 8)
        .contentShape(.rect)
        // The selected face sits on a solid block of the same blue a selected
        // sidebar row gets — one selection look, not two. That is the
        // system's selection colour, which is a shade deeper than the accent.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.selectedContentBackground)
            }
        }
    }

    private func facePicture(_ conversation: Conversation, isSelected: Bool) -> some View {
        AvatarView(conversation: conversation, size: Self.faceSize)
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
    }

    private func faceName(_ conversation: Conversation, isSelected: Bool) -> some View {
        Text(Self.title(for: conversation))
            .font(.system(size: Platform.isPhone ? 12 : 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .white : Platform.isPhone ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            // Wider than the face, so a name like "Server Monitoring" can
            // run past its edges rather than be cut to "Server M…".
            .frame(width: Platform.isPhone ? Self.faceSize + 28 : nil)
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
    /// A carry the system took over — the face's menu opened mid-press: everything back
    /// where it was, nothing reordered.
    private func cancelCarry() {
        guard !drag.settling else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag.token = nil
            drag.order = drag.base
            drag.translation = .zero
            drag.didDrag = false
        }
    }

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
    private static let avatar: CGFloat = Platform.isPhone ? 44 : 40
    /// The list's margin on a phone, the same on both sides: the avatar starts this far in
    /// and the chevron ends this far in. The unread dot sits in the gap before the avatar.
    static let phoneMargin: CGFloat = 16
    private static let textInset: CGFloat = gutter + 5 + avatar + 10
    /// iOS sets its lists in larger type, as Messages does: a 17pt name over 15pt preview.
    private static let nameSize: CGFloat = isTouch ? 17 : 15
    private static let detailSize: CGFloat = isTouch ? 15 : 12
    private static let previewSize: CGFloat = isTouch ? 15 : 13
    private static var isTouch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

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
                            .font(.system(size: Self.nameSize, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        if conversation.hasCall {
                            CallSymbol(conversation: conversation, size: 11)
                        }

                        Text(timestamp)
                            .font(.system(size: Self.detailSize))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .fixedSize()
                        if Self.isTouch {
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text(preview)
                            .font(.system(size: Self.previewSize))
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

extension View {
    /// A phone list row whose avatar starts at ``ConversationRow/phoneMargin``, the unread
    /// gutter in front of it, and whose trailing edge is the same distance in.
    func phoneRowInsets() -> some View {
        listRowInsets(Platform.isPhone
            ? EdgeInsets(top: 4, leading: ConversationRow.phoneMargin - 13, bottom: 4, trailing: ConversationRow.phoneMargin)
            : nil)
    }
}
