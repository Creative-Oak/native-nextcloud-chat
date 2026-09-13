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
        .remembersWindowFrame(named: "TalkForMacMain")
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
            } else {
                NoConversationSelected(hasConversations: !(app.conversationList?.index.isEmpty ?? true))
            }
        }
        .navigationTitle(app.chat?.conversation.displayName ?? "Talk")
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if app.connection == .offline {
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .help("Showing cached conversations. Talk for Mac will reconnect on its own.")
            }
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
            Text("Talk for Mac’s access to \(account.server.displayString) has expired or was revoked.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Sign In Again") {
                Task { await app.signOut() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}
