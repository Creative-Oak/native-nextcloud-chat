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
    /// Owned here because the To: field is the top of the draft pane, above its content.
    @State private var recipientsFocused = false
    /// How tall a strip the window reserves for the toolbar. Measured, not assumed: it is the
    /// system's number and it moves with the toolbar style. The draft's To: band is placed
    /// into that strip, which is the only way to get it onto the traffic lights' line —
    /// a toolbar item cannot, because one sizes to its content and clamps any frame.
    @State private var titleBarHeight: CGFloat = 52
    @State private var searchFocusRequest = false
    /// The command palette, while it is up. A model per showing: it starts empty.
    @State private var palette: CommandPaletteModel?
    @State private var isShowingInspector = false
    /// Set once the sidebar has given way to the inspector, so it is brought back when
    /// the inspector goes or the window grows — whoever hid it in the first place.
    @State private var didSidebarYieldToInspector = false
    @State private var contentWidth: CGFloat = 0
    @State private var conversationSettings: ConversationSettingsModel?
    @State private var messageSearch: MessageSearchModel?
    /// The message the Forward sheet is choosing a conversation for.
    @State private var forwarding: Message?
    @Environment(\.openWindow) private var openWindow

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
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            app.systemDidWake()
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
        .overlay { paletteOverlay }
        .focusedSceneValue(\.appCommands, commands)
    }

    /// Everything the menu bar and the palette can do, from the window's state right
    /// now. Rebuilt with the body, so state-dependent titles follow along.
    private var commands: AppCommandRegistry {
        var context = AppCommandRegistry.Context()
        context.hasSession = app.session != nil
        context.hasChat = app.chat != nil
        context.hasSelection = app.selectedToken != nil
        context.canCreateConversations = app.canCreateConversations
        context.canEditMessages = app.chat?.capabilities.canEditMessages == true
        context.canMarkUnread = app.chat?.capabilities.canMarkUnread == true
        context.isSidebarCompact = preferences.sidebarMode == .compact
        context.isSelectionFavorite = app.selectedToken.flatMap { app.conversationList?[$0]?.isFavorite } ?? false
        context.isSelectionArchived = app.selectedToken.flatMap { app.conversationList?[$0]?.isArchived } ?? false
        context.canArchive = app.conversationList?.hasArchive == true
        context.newConversation = { app.newMessage() }
        context.refresh = { app.refreshNow() }
        context.findConversation = requestSearchFocus
        context.findInConversation = { app.chat?.isSearching = true }
        context.searchMessages = { startMessageSearch() }
        context.toggleSidebar = toggleSidebarMode
        context.nextConversation = { app.selectRelative(offset: 1) }
        context.previousConversation = { app.selectRelative(offset: -1) }
        context.nextUnread = { app.selectNextUnread() }
        context.openPalette = openPalette
        context.focusComposer = { composerFocused = true }
        context.replyToLatest = { app.chat?.replyToLatest() }
        context.editLatest = { app.chat?.beginEditingLatestOwnMessage() }
        context.markUnread = { app.markSelectedUnread() }
        context.toggleFavorite = { app.toggleFavoriteOnSelection() }
        context.toggleArchive = { app.toggleArchiveOnSelection() }
        context.toggleInspector = toggleInspector
        context.openInBrowser = { app.openSelectionInBrowser() }
        context.showKeyboardShortcuts = { openWindow(id: TalkWindow.keyboardShortcuts) }
        context.openDocumentation = {
            if let url = URL(string: "https://nextcloud-talk.readthedocs.io/en/latest/") {
                NSWorkspace.shared.open(url)
            }
        }
        context.openSettings = { app.showSettings() }
        return .make(context)
    }

    /// Straight from the model rather than the environment: the environment's copy is
    /// optional, for views that can be previewed without one, and this view always has it.
    private var preferences: Preferences { app.dependencies.preferences }

    /// ⌘F. The search field is part of the full sidebar, so a compact sidebar widens
    /// first; the list that appears takes the request from there.
    private func requestSearchFocus() {
        if preferences.sidebarMode == .compact {
            withAnimation(.smooth(duration: 0.2)) { preferences.sidebarMode = .standard }
        }
        searchFocusRequest = true
    }

    private func toggleSidebarMode() {
        withAnimation(.smooth(duration: 0.2)) { preferences.sidebarMode.toggle() }
    }

    /// ⌘P: up, and ⌘P again puts it away, as Spotlight's does.
    private func openPalette() {
        if palette != nil {
            palette = nil
            return
        }
        palette = CommandPaletteModel(
            session: app.session,
            conversations: { app.conversationList?.index.visibleConversations ?? [] },
            commands: { commands }
        )
    }

    /// A conversation chosen in the palette: opened, and the cursor put in the message
    /// field — "⌘P, type, Return, type" is the whole flow. One that is new to the
    /// index (just created for a person) goes in the way a draft's conversation does.
    private func openFromPalette(_ conversation: Conversation) {
        palette = nil
        if app.conversationList?[conversation.token] == nil {
            app.conversationCreated(conversation)
        } else {
            app.selectedToken = conversation.token
        }
        focusComposerOnceOpen()
    }

    /// The conversation's view is created by the selection and is not there yet on the
    /// same turn; the focus request waits for it.
    private func focusComposerOnceOpen() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            composerFocused = true
        }
    }

    private var paletteOverlay: some View {
        // The `if let` inside one container with the animation on it: the palette's
        // coming and going is then one scale-and-fade, short and driven from here,
        // whichever path put it up or took it down.
        ZStack {
            if let palette {
                paletteScene(palette)
            }
        }
        .animation(.snappy(duration: 0.15), value: palette == nil)
    }

    private func paletteScene(_ palette: CommandPaletteModel) -> some View {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    // A click anywhere outside dismisses, the way Spotlight does — and
                    // nothing more: the window behind stays exactly as it was.
                    Color.black.opacity(0.001)
                        .contentShape(.rect)
                        .onTapGesture { self.palette = nil }

                    CommandPaletteView(
                        model: palette,
                        maxPanelHeight: geometry.size.height * 0.6,
                        onOpenConversation: openFromPalette,
                        onOpenMessage: { hit in
                            self.palette = nil
                            app.open(hit)
                            focusComposerOnceOpen()
                        },
                        onSeeAllMessages: { term in
                            self.palette = nil
                            startMessageSearch(term: term)
                        },
                        onDismiss: { self.palette = nil }
                    )
                    .padding(.top, geometry.size.height * 0.18)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
            }
    }

    @ViewBuilder
    private var splitView: some View {
        @Bindable var app = app
        @Bindable var preferences = preferences

        NavigationSplitView(columnVisibility: $columnVisibility) {
            // The width and the toolbar removal belong to the *column*, not to the list
            // inside it, and `SidebarColumn` always has something standing in the column
            // for them to apply to — even before the cache has opened.
            SidebarColumn(
                list: app.conversationList,
                mode: preferences.sidebarMode,
                selection: $app.selectedToken,
                composerFocused: $composerFocused,
                searchFocusRequest: searchFocusRequest,
                onSearchFocusHandled: { searchFocusRequest = false },
                draft: app.draft,
                onDiscardDraft: { app.discardDraft() },
                profile: app.profile,
                reminderCount: app.reminders?.reminders.count ?? 0,
                onOpenSettings: { app.showSettings() }
            )
            // No sidebar toggle, as in Messages: the sidebar is not something you
            // fold away by hand. It goes only when the inspector needs its room in
            // a narrow window, and comes back on its own — see `reconcileColumns`.
            // The toggle is the sidebar column's item, so the removal goes here; on
            // the split view itself it did nothing. And it goes *before* the width:
            // measured on macOS 26.6, `toolbar(removing:)` applied after
            // `navigationSplitViewColumnWidth` cancels it — the split view item keeps
            // AppKit's defaults, a 140pt minimum and no maximum, and the autosaved
            // divider position wins the next launch. Ahead of it, the width holds.
            .toolbar(removing: .sidebarToggle)
            // Pinned: one width, no range. The split view item's minimum and maximum
            // thickness are both this number, so the column sits here from the first
            // layout, moves when the number does, and there is nowhere for the saved
            // divider position to put it. A range (`min:ideal:max:`) is what let the
            // divider drag anywhere and the saved position win: `ideal` counts only the
            // first time. What a drag of the divider does now is choose between the two
            // widths — see `SidebarDividerTracker`, which also keeps the item from
            // collapsing, so a drag cannot take the column to nothing.
            .navigationSplitViewColumnWidth(preferences.sidebarMode.width)
            .background {
                SidebarDividerTracker(mode: $preferences.sidebarMode)
            }
        } detail: {
            // The inspector is a panel inside this column, not a column of its own. A
            // column brings a section of the toolbar with it, and the toolbar lays its
            // sections out against where the columns *were* while they slide, so every
            // button near the inspector jumped once the slide was over. A panel slides
            // in with its own buttons on it and asks nothing of the toolbar.
            HStack(spacing: 0) {
                Group {
                    if app.isShowingDraft, let draft = app.draft {
                        NewMessageView(
                            draft: draft,
                            recipientsFocused: $recipientsFocused,
                            titleBarHeight: titleBarHeight
                        ) { conversation in
                            app.draftSent(conversation)
                        }
                        // The pane takes the toolbar's strip so the band can sit in it. Safe
                        // in this column: the traffic lights are over the sidebar, not here.
                        .ignoresSafeArea(.container, edges: .top)
                    } else if app.isShowingSettings, let profile = app.profile {
                        SettingsPage(profile: profile)
                    } else if app.isShowingReminders, let reminders = app.reminders {
                        RemindersPage(store: reminders)
                    } else if let chat = app.chat {
                        ChatView(
                            model: chat,
                            composerFocused: $composerFocused,
                            isHeaderAlwaysFrosted: isSidebarYieldingToInspector,
                            liveConversation: app.conversationList?[chat.token],
                            reminders: app.reminders,
                            onReplyPrivately: { message in
                                Task {
                                    await app.replyPrivately(to: message)
                                    focusComposerOnceOpen()
                                }
                            },
                            onForward: { forwarding = $0 },
                            onOpenConversation: { app.selectedToken = $0 },
                            onMessageUser: { userID in
                                Task {
                                    await app.openOneToOne(with: userID)
                                    focusComposerOnceOpen()
                                }
                            }
                        )
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
                // Read here, where the safe area still exists — the draft pane above ignores
                // it, so it cannot measure its own.
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { titleBarHeight = proxy.safeAreaInsets.top }
                            .onChange(of: proxy.safeAreaInsets.top) { _, new in titleBarHeight = new }
                    }
                }

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
        .onChange(of: columnVisibility) { _, visibility in
            // The sidebar hides only for the inspector. Its split view item cannot be
            // collapsed by hand — see `SidebarDividerTracker` — but should AppKit ever
            // report it gone for another reason, it is put back rather than left with
            // no way to bring it up: there is no toggle, and ⌃⌘S changes the width.
            if visibility == .detailOnly && !isSidebarYieldingToInspector {
                withoutColumnAnimation { columnVisibility = .all }
            } else {
                reconcileColumns()
            }
        }
        .onChange(of: preferences.sidebarMode) { _, _ in reconcileColumns() }
        // Settings has no conversation to inspect; the panel goes with the conversation.
        .onChange(of: app.isShowingSettings) { _, showing in
            if showing && isShowingInspector {
                withAnimation(.smooth(duration: 0.3)) { isShowingInspector = false }
            }
        }
        .sheet(item: $conversationSettings) { model in
            ConversationSettingsSheet(model: model)
        }
        // Built fresh each time so the scope picker reflects whichever conversation is
        // open now, rather than the one that was open the first time it was used.
        .sheet(isPresented: Binding(get: { forwarding != nil }, set: { if !$0 { forwarding = nil } })) {
            if let message = forwarding {
                ForwardSheet(
                    message: message,
                    conversations: app.conversationList?.index.visibleConversations ?? [],
                    onForward: { target in
                        forwarding = nil
                        app.forward(message, to: target)
                    },
                    onCancel: { forwarding = nil }
                )
            }
        }
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
    /// full sidebar, the panel, and a conversation column wide enough to read —
    /// bubbles run to 520, and the header wants room on either side of them.
    /// Messages draws the same line at about the same place: at 860 it shows the
    /// sidebar or the inspector, never both.
    private static let widthForThreeColumnsWithFullSidebar: CGFloat = 1040

    /// The compact sidebar asks for less, by exactly the width it gives up.
    private var widthForThreeColumns: CGFloat {
        Self.widthForThreeColumnsWithFullSidebar - (SidebarMode.standard.width - preferences.sidebarMode.width)
    }

    private var isTooNarrowForThreeColumns: Bool {
        contentWidth > 0 && contentWidth < widthForThreeColumns
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

    /// With a `term`, from the palette's "See all results": the sheet opens already
    /// searching everywhere for it.
    private func startMessageSearch(term: String? = nil) {
        guard let session = app.session else { return }
        let model = MessageSearchModel(
            session: session,
            currentToken: app.chat?.token,
            currentConversationName: app.chat?.conversation.displayName
        )
        if let term {
            model.scope = .everywhere
            model.term = term
        }
        messageSearch = model
    }

    /// The conversation column's share of the toolbar: compose and search at its leading
    /// edge, nothing else. Who you are talking to is drawn by the conversation itself —
    /// see `ConversationHeader`.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // At the conversation column's leading edge, just past the sidebar, which is
        // where Messages keeps its compose button.
        // While a draft is open these stand down, so the To: band below has the top of the
        // pane to itself. The band is not a toolbar item: one sizes itself to its content
        // and clamps a frame, so it could never span the row from in here.
        //
        // Something invisible takes their place, though, and has to. A toolbar with nothing
        // in it collapses to a shorter row — which drags the traffic lights up with it, so
        // they jumped every time a draft opened, and left the band centring itself in a strip
        // that had just changed height underneath it.
        if app.isShowingDraft {
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: 1, height: GlassMetrics.control)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.newMessage()
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message (⌘N)")
            }
        }

        // Beside compose, in a circle of its own. Neighbouring items of one placement
        // share a capsule; a different placement is enough to part them. (An item that
        // opts out of the sharing is drawn bare, and an invisible item between them
        // is given the toolbar's minimum width, so neither of those would do.)
        if !app.isShowingDraft {
            ToolbarItem(placement: .automatic) {
                Button(action: openPalette) {
                    Label("Go to Anything", systemImage: "magnifyingglass")
                }
                .help("Go to Anything (⌘P)")
            }
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
        } else if app.chat != nil {
            // The way in, at the window's top-right corner, and only while there is a
            // conversation to inspect. It is an `else` on the branch above rather than a
            // separate condition, so the button and the panel's own controls can never
            // both claim that corner — the button is gone the moment the panel is there.
            ToolbarSpacer(.flexible)

            // The pins, once their bar has been hidden: Talk can't un-hide it, so this is
            // how they stay reachable. Just left of the details button, in a circle of its
            // own — a fixed spacer is what parts two items of one placement.
            if let chat = app.chat, chat.hasHiddenPins {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        PinnedMessagesMenu(model: chat) { messageID in
                            Task { await chat.reveal(messageID: messageID) }
                        }
                    } label: {
                        Label("Pinned Messages", systemImage: "pin")
                    }
                    .menuIndicator(.hidden)
                    .help("Pinned messages (\(chat.activePinCount))")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleInspector) {
                    Label("Conversation Details", systemImage: "info.circle")
                }
                .help("Show conversation details (⌥⌘I)")
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

    /// The distance between the close and Edit items that holds close
    /// `inspectorControlInset` in from the panel's leading edge: the panel's width, less
    /// the two items, the toolbar's spacing around the gap, and the inset itself.
    /// Measured, not derived; the toolbar's own spacing is its secret.
    private static let inspectorControlGap: CGFloat =
        inspectorWidth - closeWidth - editWidth - 4 * 8 + 20 - inspectorControlInset
    /// How far close sits in from the panel's leading edge. The toolbar band centres its
    /// items vertically rather than letting anything inset them, which leaves close about
    /// twelve points below the window's top edge; the leading inset is matched to that, so
    /// the button reads as sitting in a corner rather than pushed in from one.
    private static let inspectorControlInset: CGFloat = 12
    /// The close button's circle.
    private static let closeWidth: CGFloat = 32
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
