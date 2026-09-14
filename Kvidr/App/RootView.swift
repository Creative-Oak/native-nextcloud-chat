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
    @State private var isShowingNewConversation = false
    @State private var messageSearch: MessageSearchModel?

    var body: some View {
        @Bindable var app = app

        Group {
            switch app.phase {
            case .launching:
                // Deliberately blank rather than a spinner: the cache usually paints within
                // a frame or two and a flashing spinner would be worse than nothing.
                Color(nsColor: .windowBackgroundColor)

            case .signedOut:
                LoginView(app: app)

            case .needsReauthentication(let account):
                ReauthenticationView(account: account)

            case .ready:
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
            }
        } detail: {
            if let chat = app.chat {
                ChatView(model: chat, composerFocused: $composerFocused)
                    // A fresh view per conversation: no state bleeds between them.
                    .id(chat.token)
                    // The detail column contributes the title item, so it has to be
                    // removed here — on the split view it does nothing, and
                    // NSWindow.titleVisibility does not reach it either because this is
                    // a toolbar item, not the centred window title. The principal item
                    // below says who this is, with their face next to it.
                    .toolbar(removing: .title)
            } else {
                NoConversationSelected(hasConversations: !(app.conversationList?.index.isEmpty ?? true))
            }
        }
        .navigationTitle(app.chat?.conversation.displayName ?? "Talk")
        .toolbar { toolbar }
        // The Mac inspector paradigm rather than a reproduction of Talk's web sidebar: it
        // slides in beside the conversation and the transcript keeps its place.
        .inspector(isPresented: $isShowingInspector) {
            if let inspector = app.inspector {
                InspectorView(model: inspector) { messageID in
                    app.chat?.highlightRequest = messageID
                }
                .inspectorColumnWidth(min: 240, ideal: 290, max: 380)
            }
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
        .focusedSceneValue(\.inspectorToggle, { withAnimation(.smooth) { isShowingInspector.toggle() } })
    }

    private func startMessageSearch() {
        guard let session = app.session else { return }
        messageSearch = MessageSearchModel(
            session: session,
            currentToken: app.chat?.token,
            currentConversationName: app.chat?.conversation.displayName
        )
    }

    /// The toolbar *is* the conversation header, the way it is in Messages.
    ///
    /// A separate header bar underneath meant two full-height rows: the toolbar, which
    /// reserves its row across the whole window whether or not anything is in it, and the
    /// header below it. Emptying the toolbar did not reclaim that space — only moving the
    /// content up into it does.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                isShowingNewConversation = true
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            .help("New Conversation (⌘N)")
        }

        // Who you are talking to, centred, and the control that opens their details.
        ToolbarItem(placement: .principal) {
            if let chat = app.chat {
                Button {
                    withAnimation(.smooth) { isShowingInspector.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        AvatarView(conversation: chat.conversation, size: 20)
                        Text(chat.conversation.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("Conversation details")
            }
        }

        ToolbarItem(placement: .status) {
            if app.connection == .offline {
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .help("Showing cached conversations. kvidr will reconnect on its own.")
            }
        }

        ToolbarSpacer(.flexible)

        ToolbarItem {
            Button {
                isShowingQuickSwitcher = true
            } label: {
                Label("Go to Conversation", systemImage: "magnifyingglass")
            }
            .help("Go to Conversation (⌘K)")
        }

    }
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
