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
    /// Set when signing out couldn’t finish the job — an app password that may still be
    /// live on the server, or still in the keychain. Shown on the sign-in screen, which is
    /// where the user lands next and the last moment they can be told to go and revoke it
    /// by hand; after that no account row is left pointing at it.
    private(set) var signOutWarning: String?

    /// The sidebar.
    private(set) var conversationList: ConversationListModel?
    /// The open conversation, if any.
    private(set) var chat: ChatModel?
    /// The third column's state, rebuilt when the conversation changes.
    private(set) var inspector: InspectorModel?
    /// The unsent conversation, if there is one. One at a time, and in memory: an
    /// unaddressed, unsent conversation is not data yet.
    private(set) var draft: ConversationDraft?
    /// A draft's attachment queue, in the moment between the conversation existing and its
    /// `ChatModel` being built. Its files may still be going up, so it is handed over rather
    /// than left to be collected with the draft.
    @ObservationIgnored private var attachmentsInTransit: (token: String, queue: AttachmentQueue)?
    /// Each conversation's upload tray, kept for as long as the session is.
    ///
    /// A conversation is opened into a new `ChatModel` every time it is selected, and the
    /// tray used to be made fresh with it. Switching away mid-upload then took the row off
    /// screen for good while the upload carried on unseen — its failure landed in a queue
    /// nothing showed, and files staged but not yet sent were simply gone. Queues with
    /// nothing in them are let go when another conversation is opened.
    @ObservationIgnored private var attachmentQueues: [String: AttachmentQueue] = [:]

    var selectedToken: String? {
        didSet {
            guard oldValue != selectedToken else { return }
            // Neither the draft nor Settings is a conversation, and neither is restored next launch.
            if !ConversationDraftToken.isDraft(selectedToken), !SettingsToken.isSettings(selectedToken),
               !RemindersToken.isReminders(selectedToken) {
                dependencies.preferences.lastSelectedToken = selectedToken
            }
            openSelectedConversation()
        }
    }

    var isShowingDraft: Bool { ConversationDraftToken.isDraft(selectedToken) && draft != nil }
    var isShowingSettings: Bool { SettingsToken.isSettings(selectedToken) && session != nil }
    var isShowingReminders: Bool { RemindersToken.isReminders(selectedToken) && reminders != nil }

    /// The signed-in user's own picture, name and status — shared by the sidebar's account
    /// row and the Settings page, so the two can never disagree.
    private(set) var profile: ProfileModel?
    private(set) var reminders: ReminderStore?
    private var notificationPoller: NotificationPoller?

    /// Window/app activation, which gates read state. See `ReadStatePolicy`.
    var isApplicationActive = true { didSet { activationChanged() } }
    var isWindowKey = true { didSet { activationChanged() } }

    let dependencies: AppDependencies
    let notifications: NotificationController
    /// Built per session; avatars are account-scoped because the URLs are.
    private(set) var avatarLoader: AvatarLoader?
    /// Thumbnails for shared files, likewise per account.
    private(set) var previewLoader: PreviewLoader?
    /// Voice messages, one playing at a time; per account, like the previews.
    private(set) var voicePlayer: VoicePlayer?

    /// A message a search result wants shown, applied once the conversation is live.
    private var pendingReveal: Int?
    /// A message to quote once the one-to-one with its author has opened.
    private var pendingPrivateReply: Message?

    private var networkTask: Task<Void, Never>?
    private var conversationSyncTask: Task<Void, Never>?
    private var isRefreshingCapabilities = false

    init(dependencies: AppDependencies = AppDependencies()) {
        self.dependencies = dependencies
        self.notifications = NotificationController(preferences: dependencies.preferences)
        Log.isDeveloperModeEnabled = dependencies.preferences.isDeveloperModeEnabled

        notifications.isDoNotDisturb = { [weak self] in self?.profile?.status?.status == .dnd }
        notifications.onOpenMessage = { [weak self] token, messageID in
            self?.openMessage(token: token, messageID: messageID)
        }

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
            supportsConversationAvatars: account.capabilities.supportsConversationAvatars,
            sealer: CacheSealer(keyring: dependencies.cacheKeyring, accountID: account.id, kind: .avatar)
        )
        previewLoader = PreviewLoader(session: session, keyring: dependencies.cacheKeyring)
        voicePlayer = VoicePlayer(session: session, transcriber: VoiceTranscriber(preferences: dependencies.preferences))
        profile = ProfileModel(session: session)

        let list = ConversationListModel(session: session, notifications: notifications)
        list.isCurrentlyVisible = { [weak self] token in
            guard let self else { return false }
            return self.selectedToken == token && self.isApplicationActive && self.isWindowKey
        }
        conversationList = list

        let reminders = ReminderStore(session: session, notifications: notifications)
        reminders.conversation = { [weak list] token in list?[token] }
        self.reminders = reminders

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

        restoreSelection(from: list)

        startConversationSync(session: session, list: list)
        await notifications.requestAuthorizationIfNeeded()
        await reminders.load()
        startNotificationPolling(session: session)
    }

    /// Restores the previously open conversation, if it still exists.
    ///
    /// Not a plain assignment: `selectedToken`'s `didSet` is what opens a conversation, and
    /// it does nothing when the token has not changed. Rebuilding the session for a
    /// capability change comes back here with the same token still selected and the chat
    /// model already torn down, so the assignment would be silently inert and the
    /// conversation the user was reading would simply not come back.
    private func restoreSelection(from list: ConversationListModel) {
        let remembered = dependencies.preferences.lastSelectedToken
        let token = remembered.flatMap { list.index[$0] != nil ? $0 : nil }
        if selectedToken == token {
            openSelectedConversation()
        } else {
            selectedToken = token
        }
    }

    private func teardownSession() async {
        guard let session else { return }
        await chat?.deactivate()
        chat = nil
        // They belong to this session's server and credentials.
        attachmentQueues = [:]
        conversationSyncTask?.cancel()
        conversationSyncTask = nil
        await session.shutdown()
        self.session = nil
        profile = nil
        reminders?.tearDown()
        reminders = nil
        notificationPoller?.stop()
        notificationPoller = nil
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

    /// The user has read the warning from the last sign-out; stop showing it.
    func dismissSignOutWarning() {
        signOutWarning = nil
    }

    func signOut() async {
        // The account comes from whichever place has it. A live session is the usual one,
        // but the app password can stop working before a session ever exists: `start()`
        // catches a failed `activate` and goes straight to `.needsReauthentication`, with
        // `session` still nil. This used to `guard let session else { return }`, so on that
        // path the "Sign In Again" button did nothing at all and the screen had no way out
        // — not signed in, not able to sign in, not able to sign out. Any launch-time
        // keychain failure reaches it, including the orphaned credentials you get by
        // changing PRODUCT_BUNDLE_IDENTIFIER.
        var account: Account?
        if let session {
            account = session.account
        } else if case .needsReauthentication(let reauthenticating) = phase {
            account = reauthenticating
        }

        await teardownSession()

        if let account {
            let outcome = await dependencies.authentication.signOut(account: account)
            signOutWarning = outcome.warning
            // The account row goes either way. Keeping it on a failed revoke would put the
            // user back on the reauthentication screen at the next launch over a credential
            // they asked to be rid of; the warning is what carries the bad news instead.
            await dependencies.store.deleteAccount(id: account.id)
        }

        // Dropping the loader leaves the files. Their names are the user ids and room
        // tokens this account could see, so the cache outlines the account's contacts and
        // conversations for anyone who reads the directory afterwards — on a shared or
        // handed-on Mac, after the person signed out precisely so it wouldn't.
        await avatarLoader?.purge()
        await previewLoader?.purge()
        avatarLoader = nil
        previewLoader = nil
        voicePlayer?.stop()
        voicePlayer = nil
        conversationList = nil
        chat = nil
        selectedToken = nil
        dependencies.preferences.lastSelectedToken = nil
        phase = .signedOut
        notifications.updateBadge(count: 0)
    }

    func signedIn(account: Account) async {
        signOutWarning = nil
        await dependencies.store.save(account: account)
        try? await activate(account: account)
    }

    // MARK: - Selection

    private func openSelectedConversation() {
        guard let session, let token = selectedToken,
              let conversation = conversationList?.index[token]
        else {
            // Nothing is going to open, so a reveal waiting on it would otherwise fire at
            // whichever conversation the user picked next.
            pendingReveal = nil
            let previous = chat
            chat = nil
            inspector = nil
            Task { await previous?.deactivate() }
            return
        }

        inspector = InspectorModel(session: session, conversation: conversation)

        let previous = chat
        // A conversation that has just come from a draft takes the draft's queue with it,
        // files and all. Anything else gets one of its own.
        let inherited = attachmentsInTransit?.token == conversation.token
            ? attachmentsInTransit?.queue
            : attachmentQueues[conversation.token]
        attachmentsInTransit = nil

        let model = ChatModel(
            session: session,
            conversation: conversation,
            attachments: inherited,
            readContext: { [weak self] in self?.currentReadContext() ?? ReadStateContext() },
            onReadMarker: { [weak self] token, messageID in
                self?.conversationList?.markRead(token: token, upTo: messageID)
                self?.notifications.clearNotifications(for: token)
            }
        )
        model.onHiddenPinChanged = { [weak self, token = conversation.token] id in
            self?.conversationList?.setHiddenPinnedID(id, token: token)
        }
        chat = model
        attachmentQueues = attachmentQueues.filter { !$0.value.isEmpty }
        attachmentQueues[conversation.token] = model.attachments

        Task {
            // Tear the old one down *completely* first: the long-poll engine is shared, so
            // overlapping activate/stop would leave the new conversation without a sync loop.
            await previous?.deactivate()
            await model.activate()
            await self.applyPendingReveal(to: model)
            self.applyPendingPrivateReply(to: model)
        }
    }

    /// Reply Privately: the one-to-one with the message's author — the one in the sidebar,
    /// or a new one, which Talk hands back as the existing one if there is one it hadn't
    /// told us about — opened with the message quoted in the composer.
    func replyPrivately(to message: Message) async {
        pendingPrivateReply = message
        if await !openOneToOne(with: message.actor.id) {
            pendingPrivateReply = nil
        }
    }

    /// Opens the one-to-one with a user — the one in the sidebar, or a new one, which Talk
    /// hands back as the existing one if there is one it hadn't told us about.
    @discardableResult
    func openOneToOne(with userID: String) async -> Bool {
        guard let session, let list = conversationList else { return false }
        if let existing = list.index.conversations.first(where: { $0.type == .oneToOne && $0.name == userID }) {
            selectedToken = existing.token
            return true
        }
        do {
            let created = try await session.conversations.create(.oneToOne(with: userID)).conversation
            if list[created.token] == nil {
                conversationCreated(created)
            } else {
                selectedToken = created.token
            }
            return true
        } catch {
            Log.ui.warning("Couldn’t open a one-to-one conversation: \(error.userMessage)")
            return false
        }
    }

    private func applyPendingPrivateReply(to model: ChatModel) {
        guard let message = pendingPrivateReply, model.token == selectedToken,
              model.conversation.isOneToOne, model.conversation.name == message.actor.id
        else { return }
        pendingPrivateReply = nil
        model.beginReply(to: message)
    }

    /// Shows a searched-for message once its conversation has finished opening.
    ///
    /// It has to wait for activation: revealing works by paging backwards from the oldest
    /// message loaded, and before the conversation opens there is no oldest message.
    private func applyPendingReveal(to model: ChatModel) async {
        guard let messageID = pendingReveal, model.token == selectedToken else { return }
        pendingReveal = nil
        await model.reveal(messageID: messageID)
    }

    /// Opens a search result: switches to its conversation, then scrolls to the message.
    func open(_ hit: MessageSearchHit) {
        openMessage(token: hit.token, messageID: hit.messageID)
    }

    /// Switches to a conversation and scrolls to one message in it — a search result, a
    /// reminder.
    func openMessage(token: String, messageID: Int) {
        guard let chat, chat.token == token else {
            pendingReveal = messageID
            selectedToken = token
            return
        }
        // Already there — no need to wait for an activation that isn't going to happen.
        Task { await chat.reveal(messageID: messageID) }
    }

    /// The sidebar's Reminders row.
    func showReminders() {
        guard reminders != nil else { return }
        selectedToken = RemindersToken.value
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
                await self.reminders?.load()
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
            for await state in await monitor.states() {
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

    /// Called once a conversation exists: show it immediately rather than
    /// waiting for the next sync to notice it exists.
    func conversationCreated(_ conversation: Conversation) {
        conversationList?.insert(conversation)
        selectedToken = conversation.token
        refreshNow()
    }

    // MARK: - Settings

    /// ⌘, and the account row at the foot of the sidebar: Settings in the messages column.
    func showSettings() {
        guard session != nil else { return }
        selectedToken = SettingsToken.value
    }

    // MARK: - New Message

    /// ⌘N, the toolbar's compose button, and the palette's New Conversation.
    ///
    /// A second one does not make a second draft: there is one at a time, so this selects
    /// and focuses the one already open.
    func newMessage() {
        guard let session else { return }
        if draft == nil {
            draft = ConversationDraft(
                session: session,
                browsesContacts: dependencies.preferences.browsesContacts
            )
        }
        selectedToken = ConversationDraftToken.value
        draft?.requestRecipientFocus()
    }

    /// The × on the draft's row. Nothing reached the server, so nothing is deleted.
    func discardDraft() {
        draft = nil
        guard ConversationDraftToken.isDraft(selectedToken) else { return }
        // Back to whatever was open before, which is what the preference still remembers
        // because the draft never wrote to it.
        selectedToken = dependencies.preferences.lastSelectedToken
    }

    /// The draft became a real conversation: show it, and let the draft go.
    func draftSent(_ conversation: Conversation) {
        if let queue = draft?.attachments, queue.hasStaged {
            attachmentsInTransit = (conversation.token, queue)
        }
        draft = nil
        conversationCreated(conversation)
    }

    /// Forwards a message into another conversation, as ``ForwardPlan`` says: words posted
    /// again, a file shared again. The note that it went, or the error, lands on the
    /// conversation it came from.
    func forward(_ message: Message, to target: Conversation) {
        guard let session, let plan = ForwardPlan.plan(for: message) else { return }
        let source = chat
        Task {
            do throws(TalkError) {
                switch plan {
                case .text(let text):
                    _ = try await session.chat.send(token: target.token, message: text)
                case .file(let path, let caption, let isVoiceMessage):
                    try await session.attachments.share(
                        path: path, token: target.token, caption: caption, isVoiceMessage: isVoiceMessage
                    )
                }
                source?.forwardedTo = target
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    if source?.forwardedTo?.token == target.token { source?.forwardedTo = nil }
                }
            } catch {
                source?.lastError = error
            }
        }
    }

    /// See ``NotificationPoller``.
    private func startNotificationPolling(session: Session) {
        let sync = session.conversationSync
        let poller = NotificationPoller(
            service: session.serverNotifications,
            handlers: .init(
                chatActivity: {
                    Task { await sync.refreshNow(full: false) }
                },
                callStarted: { [weak self] notification in
                    guard let self, case .call(let token) = notification.kind else { return }
                    // Looking at it already: the call bar says so, and a banner on top is noise.
                    if self.selectedToken == token && self.isApplicationActive && self.isWindowKey { return }
                    self.notifications.announceCall(
                        notification,
                        in: self.conversationList?[token],
                        isDoNotDisturb: self.profile?.status?.status == .dnd
                    )
                    Task { await sync.refreshNow(full: false) }
                },
                gone: { [weak self] ids in
                    self?.notifications.withdrawCalls(ids: ids)
                }
            )
        )
        notificationPoller = poller
        poller.start()
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

    func toggleArchiveOnSelection() {
        guard let token = selectedToken, let conversation = conversationList?[token] else { return }
        conversationList?.toggleArchived(conversation)
    }

    func openSelectionInBrowser() {
        guard let token = selectedToken, let conversation = conversationList?[token] else { return }
        conversationList?.openInBrowser(conversation)
    }
}
