import AppKit
import Combine
import SwiftUI

/// The window's content: sidebar plus conversation, or the login screen.
///
/// The split view is built for three columns from the start — the inspector is simply not
/// installed yet (see docs/ARCHITECTURE.md). Adding it later doesn't disturb this layout.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var composerFocused = false
    @State private var searchFocusRequest = false
    @State private var isShowingQuickSwitcher = false
    @State private var isShowingInspector = false
    /// Set once the sidebar has given way to the inspector, so it is brought back when
    /// the inspector goes or the window grows — whoever hid it in the first place.
    @State private var didSidebarYieldToInspector = false
    @State private var contentWidth: CGFloat = 0
    @State private var isShowingNewConversation = false
    @State private var conversationSettings: ConversationSettingsModel?
    @State private var messageSearch: MessageSearchModel?

    var body: some View {
        @Bindable var app = app

        Group {
            switch app.phase {
            case .signedOut:
                LoginView(app: app)

            case .needsReauthentication(let account):
                ReauthenticationView(account: account)

            case .launching, .ready:
                // The same window from the first frame. While launching, the columns are
                // blank and the cache fills them in a moment later — the alternative, a
                // plain view until then, meant the toolbar, the sidebar and the divider all
                // appeared at once when the split view did, and the window visibly
                // rearranged itself on the way in.
                splitView
            }
        }
        .remembersWindowFrame(named: "KvidrMain")
        .task { await app.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.isApplicationActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            app.isApplicationActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            app.isWindowKey = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            app.isWindowKey = false
        }
        .overlay { quickSwitcher }
        .focusedSceneValue(\.appModel, app)
        .focusedSceneValue(\.composerFocusRequest, { composerFocused = true })
        .focusedSceneValue(\.searchFocusRequest, { searchFocusRequest = true })
        .focusedSceneValue(\.quickSwitcherRequest, { isShowingQuickSwitcher = true })
    }

    @ViewBuilder
    private var quickSwitcher: some View {
        if isShowingQuickSwitcher, let list = app.conversationList {
            ZStack(alignment: .top) {
                // A click anywhere outside dismisses, the way Spotlight does.
                Color.black.opacity(0.001)
                    .contentShape(.rect)
                    .onTapGesture { isShowingQuickSwitcher = false }

                QuickSwitcher(
                    conversations: list.index.visibleConversations,
                    onPick: { conversation in
                        isShowingQuickSwitcher = false
                        app.selectedToken = conversation.token
                    },
                    onCancel: { isShowingQuickSwitcher = false }
                )
                .padding(.top, 80)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var splitView: some View {
        @Bindable var app = app

        NavigationSplitView(columnVisibility: $columnVisibility) {
            if let list = app.conversationList {
                ConversationListView(
                    model: list,
                    selection: $app.selectedToken,
                    composerFocused: $composerFocused,
                    searchFocusRequest: searchFocusRequest,
                    onSearchFocusHandled: { searchFocusRequest = false }
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                // No sidebar toggle, as in Messages: the sidebar is not something you
                // fold away by hand. It goes only when the inspector needs its room in
                // a narrow window, and comes back on its own — see `reconcileColumns`.
                // The toggle is the sidebar column's item, so the removal goes here;
                // on the split view itself it did nothing.
                .toolbar(removing: .sidebarToggle)
            }
        } detail: {
            // The inspector is a panel inside this column, not a column of its own. A
            // column brings a section of the toolbar with it, and the toolbar lays its
            // sections out against where the columns *were* while they slide, so every
            // button near the inspector jumped once the slide was over. A panel slides
            // in with its own buttons on it and asks nothing of the toolbar.
            HStack(spacing: 0) {
                Group {
                    if let chat = app.chat {
                        ChatView(model: chat, composerFocused: $composerFocused, onShowDetails: toggleInspector)
                            // A fresh view per conversation: no state bleeds between them.
                            .id(chat.token)
                    } else if app.phase == .ready {
                        NoConversationSelected(hasConversations: !(app.conversationList?.index.isEmpty ?? true))
                    } else {
                        // Deliberately blank rather than a spinner: the cache usually
                        // paints within a frame or two and a flashing spinner would be
                        // worse than nothing. The transcript's own colour, since a
                        // transcript is what almost always replaces it.
                        Color(nsColor: .textBackgroundColor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isShowingInspector, let inspector = app.inspector {
                    InspectorView(
                        model: inspector,
                        onOpenMessage: { messageID in app.chat?.highlightRequest = messageID },
                        onSearch: { app.chat?.isSearching = true }
                    )
                    .frame(width: Self.inspectorWidth)
                    .transition(.move(edge: .trailing))
                }
            }
            // On the column, not on the chat view — these have to be true from the first
            // frame and stay true across conversations, or the toolbar visibly changes as
            // each one is mounted.
            //
            // The detail column contributes a title item; the header over the transcript
            // already says who this is, so it goes. (`NSWindow.titleVisibility` does not
            // reach it — this is a toolbar item, not the centred window title.)
            .toolbar(removing: .title)
            // No toolbar backdrop over this column: the transcript's own soft edge fade
            // is the header's background, all the way down to the name capsule. Left
            // visible, AppKit paints its opaque, hairlined backdrop over the toolbar.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar { detailToolbar }
        }
        .navigationTitle(app.chat?.conversation.displayName ?? "Talk")
        // Three columns need room. Below it, the sidebar gives way to the inspector,
        // as it does in Messages, and comes back when the inspector closes or the
        // window grows — rather than all three squeezing each other into clipped
        // fragments and an overflowing toolbar.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
            reconcileColumns()
        }
        .onChange(of: isShowingInspector) { _, _ in reconcileColumns() }
        .onChange(of: columnVisibility) { _, _ in reconcileColumns() }
        .sheet(item: $conversationSettings) { model in
            ConversationSettingsSheet(model: model)
        }
        .sheet(isPresented: $isShowingNewConversation) {
            if let session = app.session {
                NewConversationSheet(session: session) { conversation in
                    isShowingNewConversation = false
                    app.conversationCreated(conversation)
                }
            }
        }
        // Built fresh each time so the scope picker reflects whichever conversation is
        // open now, rather than the one that was open the first time it was used.
        .sheet(item: $messageSearch) { model in
            MessageSearchSheet(
                model: model,
                onOpen: { hit in
                    messageSearch = nil
                    app.open(hit)
                },
                onClose: { messageSearch = nil }
            )
        }
        .focusedSceneValue(\.newConversationRequest, { isShowingNewConversation = true })
        .focusedSceneValue(\.messageSearchRequest, { startMessageSearch() })
        .focusedSceneValue(\.inspectorToggle, toggleInspector)
    }

    /// Messages' panel width, near enough. Fixed: the panel is a card, not a column.
    private static let inspectorWidth: CGFloat = 300

    private func toggleInspector() {
        if isShowingInspector {
            withAnimation(.smooth(duration: 0.3)) { isShowingInspector = false }
        } else {
            if isTooNarrowForThreeColumns {
                didSidebarYieldToInspector = true
                withoutColumnAnimation { columnVisibility = .detailOnly }
                relayoutToolbar()
            }
            withAnimation(.smooth(duration: 0.3)) { isShowingInspector = true }
        }
    }

    /// The sidebar yields and returns in one step rather than sliding. Animated, the
    /// toolbar settled its sections against the columns' positions mid-slide and only
    /// corrected itself afterwards, so the buttons jumped. One step, then one relayout,
    /// is instant and never wrong. (The inspector is a panel, not a column, and slides
    /// freely — see the detail column.)
    private func withoutColumnAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    /// Makes the toolbar lay its items out again, on the next turn.
    ///
    /// When a column appears or goes, the toolbar's sections follow the column
    /// dividers — but it does not always look again after the columns have moved, and
    /// then the conversation's search button sits in the inspector's section until the
    /// window is resized. This is that resize: a point wider and straight back, before
    /// anything is drawn.
    private func relayoutToolbar() {
        Task { @MainActor in
            guard let window = NSApp.windows.first(where: { $0.frameAutosaveName == "KvidrMain" }) else { return }
            let frame = window.frame
            var nudged = frame
            nudged.size.width += 1
            window.setFrame(nudged, display: false)
            window.setFrame(frame, display: false)
        }
    }

    /// Sidebar, conversation and inspector side by side need about this much: the
    /// sidebar at its ideal width, the panel, and a conversation column wide enough to
    /// read — bubbles run to 520, and the header wants room on either side of them.
    /// Messages draws the same line at about the same place: at 860 it shows the
    /// sidebar or the inspector, never both.
    private static let widthForThreeColumns: CGFloat = 1040

    private var isTooNarrowForThreeColumns: Bool {
        contentWidth > 0 && contentWidth < Self.widthForThreeColumns
    }

    /// The inspector is open and there is no room for the sidebar beside it. Holds
    /// however the sidebar came to be hidden, and however it might be asked back:
    /// closing the inspector, or widening the window, is what brings it back.
    private var isSidebarYieldingToInspector: Bool {
        isShowingInspector && isTooNarrowForThreeColumns
    }

    private func reconcileColumns() {
        if isSidebarYieldingToInspector {
            didSidebarYieldToInspector = true
            guard columnVisibility != .detailOnly else { return }
            withoutColumnAnimation { columnVisibility = .detailOnly }
            relayoutToolbar()
        } else if didSidebarYieldToInspector {
            didSidebarYieldToInspector = false
            withoutColumnAnimation { columnVisibility = .all }
            relayoutToolbar()
        }
    }

    private func startMessageSearch() {
        guard let session = app.session else { return }
        messageSearch = MessageSearchModel(
            session: session,
            currentToken: app.chat?.token,
            currentConversationName: app.chat?.conversation.displayName
        )
    }

    /// The conversation column's share of the toolbar: compose and search at its leading
    /// edge, nothing else. Who you are talking to is drawn by the conversation itself —
    /// see `ConversationHeader`.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // At the conversation column's leading edge, just past the sidebar, which is
        // where Messages keeps its compose button.
        ToolbarItem(placement: .navigation) {
            Button {
                isShowingNewConversation = true
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            .help("New Conversation (⌘N)")
        }

        // Beside compose, in a circle of its own. Neighbouring items of one placement
        // share a capsule; a different placement is enough to part them. (An item that
        // opts out of the sharing is drawn bare, and an invisible item between them
        // is given the toolbar's minimum width, so neither of those would do.)
        ToolbarItem(placement: .automatic) {
            Button {
                isShowingQuickSwitcher = true
            } label: {
                Label("Go to Conversation", systemImage: "magnifyingglass")
            }
            .help("Go to Conversation (⌘K)")
        }

        // Conditional rather than an item that is sometimes empty: an empty item still
        // takes a slot, and slots are what push the rest of the row into the overflow menu.
        if app.connection == .offline {
            ToolbarItem(placement: .navigation) {
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .help("Showing cached conversations. kvidr will reconnect on its own.")
            }
        }

        // The inspector's controls, in the toolbar band over the panel: close at its
        // top-left corner, Edit at its top-right, as in Messages. They are toolbar
        // items because the band takes every click, so nothing drawn on the panel
        // itself could sit up here. This is the trailing edge of the conversation
        // column's section, and since the panel is not a column that edge is always
        // the window's edge — it never moves, so nothing here jumps. Close is held at
        // the panel's far corner by an invisible item of the right width between the
        // two, since a toolbar has no other way to put an item at a chosen distance
        // from its edge.
        if isShowingInspector, let inspector = app.inspector {
            // Pushes the rest to the trailing edge; without it the section packs
            // everything from the left, placement or no placement.
            ToolbarSpacer(.flexible)

            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleInspector) {
                    Label("Close", systemImage: "xmark")
                }
                .help("Hide conversation details")
            }

            let canEdit = inspector.conversation.isModerator || inspector.conversation.canLeaveConversation
            toolbarGap(width: canEdit ? Self.inspectorControlGap : Self.inspectorControlGap + Self.editWidth, placement: .primaryAction)

            if let session = app.session, canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        conversationSettings = ConversationSettingsModel(session: session, conversation: inspector.conversation)
                    }
                    .help("Conversation settings")
                }
            }
        }
    }

    /// An item that draws nothing: a fixed gap between the items either side of it,
    /// which also parts them into separate glass shapes.
    private func toolbarGap(width: CGFloat, placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            Color.clear.frame(width: width, height: 1)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// The distance between the close and Edit items that lands close ten points in
    /// from the panel's top-left corner, matching Edit's inset from the window's edge:
    /// the panel's width, less the two items, the toolbar's spacing around the gap,
    /// and that inset. Measured, not derived; the toolbar's own spacing is its secret.
    private static let inspectorControlGap: CGFloat = inspectorWidth - 32 - editWidth - 4 * 8 + 2
    /// The Edit capsule's width.
    private static let editWidth: CGFloat = 50
}

private struct NoConversationSelected: View {
    let hasConversations: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(hasConversations
                 ? "Pick a conversation from the sidebar, or press ↑ and ↓ to move through them."
                 : "Conversations from Nextcloud Talk will appear in the sidebar.")
        }
    }
}

/// Shown when the app password stopped working. Everything cached stays readable.
private struct ReauthenticationView: View {
    let account: Account
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign in again")
                .font(.title2.weight(.semibold))
            Text("kvidr’s access to \(account.server.displayString) has expired or was revoked.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Sign In Again") {
                Task { await app.signOut() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}
