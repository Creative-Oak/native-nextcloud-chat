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

    private var networkTask: Task<Void, Never>?
    private var conversationSyncTask: Task<Void, Never>?

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
    func activate(account: Account) async throws {
        let session = try dependencies.makeSession(account: account)
        self.session = session
        avatarLoader = AvatarLoader(
            client: session.client,
            server: account.server,
            supportsConversationAvatars: account.capabilities.supportsConversationAvatars
        )
        phase = .ready

        let list = ConversationListModel(session: session, notifications: notifications)
        conversationList = list

        await list.loadFromCache()

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

    func signOut() async {
        guard let session else { return }
        await session.shutdown()
        conversationSyncTask?.cancel()
        await dependencies.authentication.signOut(account: session.account)
        await dependencies.store.deleteAccount(id: session.account.id)

        self.session = nil
        avatarLoader = nil
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
            chat?.deactivate()
            chat = nil
            return
        }

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
            // Tear the old one down first, so two long polls never overlap.
            previous?.deactivate()
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
