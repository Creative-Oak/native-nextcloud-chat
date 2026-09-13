import Foundation
import Observation
import SwiftUI

/// Root application state: which account is signed in, which conversation is selected, and
/// whether the window is in a position to mark anything read.
///
/// Deliberately small. Feature state lives in the feature models this owns; putting it all
/// here is how a SwiftUI app ends up re-rendering everything on every keystroke.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case ready
        /// Signed in, but the app password stopped working.
        case needsReauthentication(Account)
    }

    private(set) var phase: Phase = .launching
    private(set) var session: Session?
    private(set) var connection: ConnectionState = .online

    /// The sidebar.
    private(set) var conversationList: ConversationListModel?
    /// The open conversation, if any.
    private(set) var chat: ChatModel?
    /// The third column's state, rebuilt when the conversation changes.
    private(set) var inspector: InspectorModel?

    var selectedToken: String? {
        didSet {
            guard oldValue != selectedToken else { return }
            dependencies.preferences.lastSelectedToken = selectedToken
            openSelectedConversation()
        }
    }

    /// Window/app activation, which gates read state. See `ReadStatePolicy`.
    var isApplicationActive = true { didSet { activationChanged() } }
    var isWindowKey = true { didSet { activationChanged() } }

    let dependencies: AppDependencies
    let notifications: NotificationController
    /// Built per session; avatars are account-scoped because the URLs are.
    private(set) var avatarLoader: AvatarLoader?
    /// Thumbnails for shared files, likewise per account.
    private(set) var previewLoader: PreviewLoader?

    private var networkTask: Task<Void, Never>?
    private var conversationSyncTask: Task<Void, Never>?
    private var isRefreshingCapabilities = false

    init(dependencies: AppDependencies = AppDependencies()) {
        self.dependencies = dependencies
        self.notifications = NotificationController(preferences: dependencies.preferences)
        Log.isDeveloperModeEnabled = dependencies.preferences.isDeveloperModeEnabled

        // Clicking a notification opens that conversation.
        notifications.onOpenConversation = { [weak self] token in
            self?.selectedToken = token
        }
    }

    // MARK: - Lifecycle

    func start() async {
        observeNetwork()

        let accounts = await dependencies.store.accounts()
        guard let account = accounts.first else {
            phase = .signedOut
            return
        }

        do {
            try await activate(account: account)
        } catch {
            Log.auth.error("Couldn’t restore the signed-in account: \(error.localizedDescription)")
            phase = .needsReauthentication(account)
        }
    }

    /// Brings an account online: cache first, network second. The sidebar is painted from
    /// the cache before any request is made, which is what makes launch feel instant.
    ///
    /// Safe to call again for the same account — it tears the previous session down first,
    /// which is what makes a capability refresh possible without restarting the app.
    func activate(account: Account) async throws {
        await teardownSession()

        let session = try dependencies.makeSession(account: account)
        self.session = session
        avatarLoader = AvatarLoader(
            client: session.client,
            supportsConversationAvatars: account.capabilities.supportsConversationAvatars
        )
        previewLoader = PreviewLoader(session: session)

        let list = ConversationListModel(session: session, notifications: notifications)
        list.isCurrentlyVisible = { [weak self] token in
            guard let self else { return false }
            return self.selectedToken == token && self.isApplicationActive && self.isWindowKey
        }
        conversationList = list

        // Paint from the cache *before* going to `.ready`, so the window never flashes an
        // empty "No Conversations" state on the way in.
        await list.loadFromCache()
        phase = .ready

        // The server tells us its Talk configuration changed by changing this hash; that is
        // the documented signal to refetch capabilities, and the only one we act on.
        await session.capabilities.preload(account.capabilities, hash: account.talkHash)
        await session.client.onTalkHashChange { [weak self] hash in
            Task { @MainActor in await self?.talkConfigurationChanged(hash: hash) }
        }

        // Restore the previous selection if it still exists.
        let remembered = dependencies.preferences.lastSelectedToken
        if let remembered, list.index[remembered] != nil {
            selectedToken = remembered
        } else {
            selectedToken = nil
        }

        startConversationSync(session: session, list: list)
        await notifications.requestAuthorizationIfNeeded()
    }

    private func teardownSession() async {
        guard let session else { return }
        await chat?.deactivate()
        chat = nil
        conversationSyncTask?.cancel()
        conversationSyncTask = nil
        await session.shutdown()
        self.session = nil
    }

    /// The server's Talk configuration changed — refetch capabilities and rebuild around
    /// them, so a feature that was just enabled (or disabled) takes effect without a relaunch.
    private func talkConfigurationChanged(hash: String) async {
        guard let session, !isRefreshingCapabilities else { return }
        isRefreshingCapabilities = true
        defer { isRefreshingCapabilities = false }

        await session.capabilities.invalidate(newHash: hash)
        guard let refreshed = try? await session.capabilities.capabilities(force: true) else { return }

        var account = session.account
        guard refreshed != account.capabilities || account.talkHash != hash else { return }
        account.capabilities = refreshed
        account.talkHash = hash
        await dependencies.store.save(account: account)

        Log.sync.info("Talk capabilities changed; rebuilding the session")
        try? await activate(account: account)
    }

    func signOut() async {
        guard let session else { return }
        let account = session.account
        await teardownSession()
        await dependencies.authentication.signOut(account: account)
        await dependencies.store.deleteAccount(id: account.id)

        avatarLoader = nil
        previewLoader = nil
        conversationList = nil
        chat = nil
        selectedToken = nil
        dependencies.preferences.lastSelectedToken = nil
        phase = .signedOut
        notifications.updateBadge(count: 0)
    }

    func signedIn(account: Account) async {
        await dependencies.store.save(account: account)
        try? await activate(account: account)
    }

    // MARK: - Selection

    private func openSelectedConversation() {
        guard let session, let token = selectedToken,
              let conversation = conversationList?.index[token]
        else {
            let previous = chat
            chat = nil
            inspector = nil
            Task { await previous?.deactivate() }
            return
        }

        inspector = InspectorModel(session: session, conversation: conversation)

        let previous = chat
        let model = ChatModel(
            session: session,
            conversation: conversation,
            readContext: { [weak self] in self?.currentReadContext() ?? ReadStateContext() },
            onReadMarker: { [weak self] token, messageID in
                self?.conversationList?.markRead(token: token, upTo: messageID)
                self?.notifications.clearNotifications(for: token)
            }
        )
        chat = model

        Task {
            // Tear the old one down *completely* first: the long-poll engine is shared, so
            // overlapping activate/stop would leave the new conversation without a sync loop.
            await previous?.deactivate()
            await model.activate()
        }
    }

    /// Everything the read-state policy needs to know about the window right now.
    func currentReadContext(isScrolledToLatest: Bool = true) -> ReadStateContext {
        ReadStateContext(
            isSelected: selectedToken != nil,
            isApplicationActive: isApplicationActive,
            isWindowKey: isWindowKey,
            isScrolledToLatest: isScrolledToLatest,
            userMarkedUnread: chat?.userMarkedUnread ?? false
        )
    }

    private func activationChanged() {
        guard let session else { return }
        let context = currentReadContext(isScrolledToLatest: chat?.isScrolledToLatest ?? false)
        let isActive = isApplicationActive
        let chat = self.chat

        Task {
            await session.chatSync.setReadContext(context)
            if isActive {
                // Coming back to the app is the moment to notice anything we missed.
                await session.conversationSync.applicationDidBecomeActive()
                await chat?.applicationDidBecomeActive()
            } else {
                await session.conversationSync.applicationDidResignActive()
            }
        }
    }

    // MARK: - Sync plumbing

    private func startConversationSync(session: Session, list: ConversationListModel) {
        conversationSyncTask?.cancel()
        conversationSyncTask = Task { [weak self] in
            let cursor = await session.store.syncState(accountID: session.account.id)
            await session.conversationSync.seed(modifiedSince: cursor.conversationsModifiedSince)

            for await event in await session.conversationSync.start() {
                guard let self else { return }
                switch event {
                case .conversations(let result):
                    await list.apply(result)
                    self.notifications.updateBadge(count: list.totalUnreadCount)
                case .offline(let isOffline):
                    self.connection = isOffline ? .offline : .online
                case .failed(let error) where error.requiresReauthentication:
                    self.phase = .needsReauthentication(session.account)
                case .failed:
                    break
                }
            }
        }
        
    }

    private func observeNetwork() {
        networkTask?.cancel()
        let monitor = dependencies.network
        networkTask = Task { [weak self] in
            for await state in monitor.states() {
                guard let self else { return }
                self.connection = state
                if state == .online, let session = self.session {
                    // Back on the network: refresh fully, since anything could have changed.
                    let sync = session.conversationSync
                    let chat = self.chat
                    await sync.refreshNow(full: true)
                    await chat?.reconnect()
                }
            }
        }
    }

    var canCreateConversations: Bool {
        session?.capabilitySnapshot.canCreateConversations ?? false
    }

    /// Called after the New Conversation sheet creates one: show it immediately rather than
    /// waiting for the next sync to notice it exists.
    func conversationCreated(_ conversation: Conversation) {
        conversationList?.insert(conversation)
        selectedToken = conversation.token
        refreshNow()
    }

    func refreshNow() {
        guard let session else { return }
        let sync = session.conversationSync
        Task { await sync.refreshNow(full: true) }
    }

    // MARK: - Menu commands
    //
    // These live here rather than in the views because the menu bar is outside the view
    // hierarchy and reaches the current window through focused values.

    func selectRelative(offset: Int) {
        guard let next = conversationList?.conversation(after: selectedToken, offset: offset) else { return }
        selectedToken = next.token
    }

    func selectNextUnread() {
        guard let next = conversationList?.nextUnread(after: selectedToken) else { return }
        selectedToken = next.token
    }

    func markSelectedUnread() {
        guard let chat, let list = conversationList else { return }
        // ChatModel sends the request; the list only needs the local echo, or we'd send two.
        chat.markUnread()
        list.showUnread(token: chat.token)
        // Leaving it selected would immediately mark it read again, which is not what the
        // command means.
        selectedToken = nil
    }

    func toggleFavoriteOnSelection() {
        guard let token = selectedToken, let conversation = conversationList?[token] else { return }
        conversationList?.toggleFavorite(conversation)
    }

    func openSelectionInBrowser() {
        guard let token = selectedToken, let conversation = conversationList?[token] else { return }
        conversationList?.openInBrowser(conversation)
    }
}
