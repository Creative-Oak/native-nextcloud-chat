import Foundation
import Observation

/// The open conversation.
///
/// Owns a ``MessageTimeline`` (merge rules), the sync subscription, the outbox, and the
/// read-state decision for this conversation. One instance per opened conversation; it is
/// torn down deterministically when the selection changes.
@MainActor
@Observable
final class ChatModel {
    private(set) var conversation: Conversation
    private(set) var timeline = MessageTimeline()
    /// The other person's out-of-office, in a one-to-one, while they're away.
    var absence: Absence?
    /// Where a message was just forwarded, for the note at the top of the transcript.
    var forwardedTo: Conversation?
    /// This user's messages waiting to be sent, soonest first. See `ChatModel+Scheduled`.
    var scheduled: [ScheduledMessage] = []
    /// Set from the composer's Send Later: the next message is scheduled for then instead.
    var sendLater: Date?
    /// A scheduled message taken back into the composer to be changed.
    var editingScheduled: ScheduledMessage?
    @ObservationIgnored var scheduledRefresh: Task<Void, Never>?
    /// Pinned messages, most recently pinned first. See `ChatModel+Pins`.
    var pins: [PinnedMessage] = []
    /// The pin this user dismissed the pinned bar for.
    var hiddenPinnedID = 0
    /// The latest pin as last seen, to notice when it changes — see `ChatModel+Pins`.
    var latestPinID = 0
    /// Set by the app: the sidebar's copy of the conversation follows a hide, so reopening
    /// the conversation doesn't bring back a bar that was just dismissed.
    var onHiddenPinChanged: (Int) -> Void = { _ in }
    /// The transcript's display list. Rebuilt when the timeline changes — never per render.
    private(set) var rows: [ChatRow] = []
    /// Files on their way into this conversation.
    let attachments: AttachmentQueue
    private(set) var syncState: ChatSyncState = .idle
    private(set) var isLoadingOlder = false
    /// False once we've paged back to the beginning of the conversation.
    private(set) var canLoadOlder = true
    /// Shown as a quiet inline bar, never as a modal alert.
    var lastError: TalkError?

    /// The user explicitly chose Mark as Unread; nothing may quietly undo that.
    private(set) var userMarkedUnread = false
    /// Whether the newest message is on screen — one of the four read-state conditions.
    var isScrolledToLatest = true {
        didSet {
            guard oldValue != isScrolledToLatest else { return }
            pushReadContext()
            if isScrolledToLatest { markReadIfPossible() }
        }
    }

    // MARK: - Search

    /// The in-conversation find bar (⌥⌘F).
    var isSearching = false {
        didSet { if !isSearching { searchText = "" } }
    }

    var searchText = "" {
        didSet { refreshSearch() }
    }

    private(set) var searchMatches: [MessageSearch.Match] = []
    private(set) var currentMatch = 0

    private func refreshSearch() {
        searchMatches = MessageSearch.matches(in: timeline.messages, query: searchText, parser: parser)
        currentMatch = 0
        if let first = searchMatches.first { highlightRequest = first.messageID }
    }

    /// ⌘G and ⇧⌘G, and the chevrons in the find bar.
    func stepSearch(by offset: Int) {
        guard !searchMatches.isEmpty else { return }
        currentMatch = (currentMatch + offset + searchMatches.count) % searchMatches.count
        highlightRequest = searchMatches[currentMatch].messageID
    }

    func jump(to match: MessageSearch.Match) {
        guard let index = searchMatches.firstIndex(of: match) else { return }
        currentMatch = index
        highlightRequest = match.messageID
    }

    /// Set to ask the transcript to scroll to and flash a message — used by the inspector's
    /// "show in conversation" and by tapping a reply's quote.
    var highlightRequest: Int?
    /// The message being replied to, shown above the composer.
    var replyingTo: Message?
    /// The message being edited, if any.
    var editing: Message?
    /// The id the "new messages" separator sits above; frozen when the conversation opens
    /// so it doesn't jump around while the user is reading.
    private(set) var firstUnreadMessageID: Int?

    let session: Session
    private let readContext: @MainActor () -> ReadStateContext
    private let onReadMarker: @MainActor (String, Int) -> Void

    private var syncTask: Task<Void, Never>?
    private var pendingReadMarker: Int = 0
    private var isSendingReadMarker = false

    /// Parsed message content, keyed by row identity. Not observed: it is a memo of a pure
    /// function, and making it observable would invalidate the view that filled it.
    @ObservationIgnored private var contentCache: [String: (source: String, content: MessageContent)] = [:]
    @ObservationIgnored private lazy var parser = MessageContentParser(
        currentUserID: session.account.userID,
        markdownEnabled: session.capabilitySnapshot.supportsMarkdown
    )

    var token: String { conversation.token }
    var capabilities: TalkCapabilities { session.capabilitySnapshot }
    var messages: [Message] { timeline.messages }

    /// Every timeline mutation goes through here so the display list and the timeline can
    /// never disagree.
    func mutateTimeline(_ body: (inout MessageTimeline) -> Void) {
        body(&timeline)
        rebuildRows()
    }

    /// In a one-to-one, whether the other person is out of office now — as Talk's web app
    /// shows it. A conversation with anyone else, or a server without the calendar app's
    /// endpoint, simply has none.
    func loadAbsence() async {
        guard conversation.type == .oneToOne, let partner = conversation.oneToOnePartnerID else { return }
        do throws(TalkError) {
            absence = try await session.absences.currentAbsence(userID: partner)
        } catch {
            Log.ui.info("No out-of-office for this conversation: \(error.userMessage)")
        }
    }

    /// The sidebar synced a newer copy of this conversation — a rename, a new picture, changed
    /// permissions. Taken over, except for what this model has moved on itself: how far it has
    /// read.
    func conversationChanged(_ fresh: Conversation) {
        guard fresh.token == conversation.token, fresh != conversation else { return }
        var merged = fresh
        if conversation.lastReadMessageID > fresh.lastReadMessageID {
            merged.lastReadMessageID = conversation.lastReadMessageID
            merged.unreadMessages = conversation.unreadMessages
        }
        conversation = merged
    }

    func rebuildRows() {
        rows = ChatRow.build(messages: timeline.messages, firstUnreadMessageID: firstUnreadMessageID)
    }

    /// Parsed content for a message, memoized. Re-parses only when the text actually
    /// changed (an edit), which is what keeps scrolling cheap.
    func content(for message: Message) -> MessageContent {
        let source = message.text
        if let cached = contentCache[message.localID], cached.source == source {
            return cached.content
        }
        let parsed = parser.parse(message)
        contentCache[message.localID] = (source, parsed)
        return parsed
    }

    /// True when this message is mine — drives the subtle "my messages" treatment.
    func isFromMe(_ message: Message) -> Bool {
        session.account.isMe(message.actor)
    }

    /// - Parameter attachments: a queue to take over rather than make. A conversation that
    ///   has just come from a draft inherits the draft's, because its files may still be
    ///   going up — making a fresh one here would drop them mid-upload.
    init(
        session: Session,
        conversation: Conversation,
        attachments: AttachmentQueue? = nil,
        readContext: @escaping @MainActor () -> ReadStateContext,
        onReadMarker: @escaping @MainActor (String, Int) -> Void
    ) {
        self.session = session
        self.conversation = conversation
        self.attachments = attachments ?? AttachmentQueue(session: session, token: conversation.token)
        self.readContext = readContext
        self.onReadMarker = onReadMarker
        self.hiddenPinnedID = conversation.hiddenPinnedID
        self.latestPinID = conversation.lastPinnedID
    }

    // MARK: - Lifecycle

    func activate() async {
        // Cache first: an already-read conversation opens with its history on screen in the
        // same frame, with no spinner and no flash of empty state.
        let cached = await session.store.messages(token: token, accountID: session.account.id, limit: 200)
        mutateTimeline { $0.apply(cached.filter { !$0.deliveryState.isPending }) }
        restorePendingMessages(from: cached)
        firstUnreadMessageID = computeFirstUnread()
        rebuildRows()

        await restoreDraft()
        pushReadContext()

        syncTask?.cancel()
        let token = self.token
        let lastKnown = timeline.lastServerMessageID
        let sync = session.chatSync
        syncTask = Task { [weak self] in
            for await event in await sync.activate(token: token, lastKnownMessageID: lastKnown) {
                guard let self else { return }
                await self.handle(event)
            }
        }
        Task { await loadPins() }
        Task { await loadScheduled() }
        Task { await loadAbsence() }
    }

    /// Async on purpose. The long-poll engine is shared between conversations, so the
    /// previous conversation's stop has to *complete* before the next one starts — otherwise
    /// a stop scheduled from the old model can land after the new model's activate and kill
    /// the subscription that just opened.
    func deactivate() async {
        syncTask?.cancel()
        syncTask = nil
        saveDraftNow()
        // The separator belongs to this visit; it shouldn't still be sitting there next time.
        clearUnreadSeparator()
        await session.chatSync.stop()
    }

    func applicationDidBecomeActive() async {
        pushReadContext()
        markReadIfPossible()
    }

    func reconnect() async {
        // Any state the loop is retrying from, not just the one spelled `.offline`. A poll
        // dropped by a captive portal, a VPN or a server going away surfaces as `.timedOut`
        // or `.transport` (see `URLSessionTransport.map`), which lands on `.reconnecting` —
        // and the conversation would then sit out its own backoff, up to thirty seconds,
        // while the sidebar beside it refreshed the moment the network came back.
        guard syncTask == nil || syncState.isRetrying else { return }
        await activate()
    }

    private func handle(_ event: ChatSyncEvent) async {
        switch event {
        case .state(let state):
            syncState = state
            if state == .live { lastError = nil }
        case .failed(let error):
            lastError = error
        case .messages(let batch):
            await apply(batch)
        }
    }

    private func apply(_ batch: ChatBatch) async {
        var change = MessageTimeline.Change()
        mutateTimeline { change = $0.apply(batch.messages) }
        guard !change.isEmpty else { return }

        await session.store.save(messages: batch.messages, accountID: session.account.id)

        // A message of mine arriving may be a scheduled one going out.
        if !scheduled.isEmpty, batch.messages.contains(where: { session.account.isMe($0.actor) }) {
            Task { await loadScheduled() }
        }

        // Someone pinned or unpinned something: the list is the truth, so read it again.
        if batch.messages.contains(where: { PinnedMessage.changeSystemMessages.contains($0.systemMessage) }) {
            Task { await loadPins() }
        }

        // Messages arriving while the user is reading history get a "new messages" line of
        // their own, so they can see where they were when they scroll back down.
        if firstUnreadMessageID == nil, !isScrolledToLatest, change.appendedAtEnd,
           let firstIncoming = batch.messages.first(where: { $0.isVisible && !session.account.isMe($0.actor) }) {
            firstUnreadMessageID = firstIncoming.messageID
            rebuildRows()
        }

        markReadIfPossible()
    }

    // MARK: - History

    /// Pages backwards. Called when the user scrolls near the top.
    func loadOlder() async {
        guard canLoadOlder, !isLoadingOlder else { return }
        let oldest = timeline.firstServerMessageID
        guard oldest > 0 else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do throws(TalkError) {
            let batch = try await session.chatSync.loadOlder(token: token, before: oldest)
            if batch.messages.isEmpty {
                canLoadOlder = false
            } else {
                mutateTimeline { $0.apply(batch.messages) }
                await session.store.save(messages: batch.messages, accountID: session.account.id)
                canLoadOlder = batch.mayHaveMore
            }
        } catch {
            lastError = error
            Log.chat.warning("Couldn’t load older messages: \(error.userMessage)")
        }
    }

    /// How far back ``reveal(messageID:)`` will page before giving up.
    ///
    /// A hit from the server can be years old. Paging to it is a request per page, so there
    /// has to be a limit; past it the honest answer is to offer the web UI, which can jump
    /// straight there.
    static let revealPageLimit = 12

    /// True while the transcript is paging backwards to reach a searched-for message.
    private(set) var isRevealing = false

    /// Set when a search result turned out to be further back than the transcript will
    /// page. The transcript offers to open it in Nextcloud instead.
    private(set) var unreachableMessageID: Int?

    func dismissUnreachableMessage() { unreachableMessageID = nil }

    /// The conversation in the Nextcloud web UI.
    var webURL: URL {
        session.account.server.url(path: "/index.php/call/\(token)")
    }

    /// Where the Nextcloud web UI shows one message. The fragment is the anchor Talk's own
    /// search results use.
    func webURL(forMessage messageID: Int) -> URL {
        session.account.server.url(path: "/index.php/call/\(token)#message_\(messageID)")
    }

    /// Scrolls to a message, loading history until it appears.
    ///
    /// Returns false when the message is further back than ``revealPageLimit`` pages, or
    /// the conversation ran out of history without it — the caller then has the choice of
    /// opening it in Nextcloud instead.
    @discardableResult
    func reveal(messageID: Int) async -> Bool {
        guard messageID > 0 else { return false }
        unreachableMessageID = nil
        if timeline.message(id: messageID) != nil {
            highlightRequest = messageID
            return true
        }

        isRevealing = true
        defer {
            isRevealing = false
            if timeline.message(id: messageID) == nil { unreachableMessageID = messageID }
        }

        for _ in 0..<Self.revealPageLimit {
            // A scroll-driven page may already be in flight; `loadOlder` would no-op and
            // this loop would read that as "no progress" and give up short of the message.
            while isLoadingOlder {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return false }
            }
            if timeline.message(id: messageID) != nil {
                highlightRequest = messageID
                return true
            }

            let oldestBefore = timeline.firstServerMessageID
            // Already past it: the message is missing from a stretch we have loaded, which
            // means it was deleted or expired rather than being further back.
            if oldestBefore > 0, messageID > oldestBefore { return false }
            guard canLoadOlder else { return false }

            await loadOlder()
            if timeline.message(id: messageID) != nil {
                highlightRequest = messageID
                return true
            }
            // No progress — a failed request, or the beginning of the conversation.
            if timeline.firstServerMessageID == oldestBefore { return false }
        }
        return false
    }

    // MARK: - Read state

    private func pushReadContext() {
        let context = currentContext()
        let sync = session.chatSync
        Task { await sync.setReadContext(context) }
    }

    private func currentContext() -> ReadStateContext {
        var context = readContext()
        context.isScrolledToLatest = isScrolledToLatest
        context.userMarkedUnread = userMarkedUnread
        return context
    }

    /// The one place a message becomes "read".
    func markReadIfPossible() {
        let latest = timeline.lastServerMessageID
        guard let marker = ReadStatePolicy.readMarker(
            context: currentContext(),
            latestVisibleMessageID: latest,
            lastReadMessageID: conversation.lastReadMessageID
        ) else { return }

        conversation.lastReadMessageID = marker
        conversation.unreadMessages = 0
        onReadMarker(token, marker)
        sendReadMarker(marker)
    }

    /// The highest marker this conversation has actually told the server about.
    private var sentReadMarker = 0

    private func sendReadMarker(_ messageID: Int) {
        guard capabilities.canSetReadMarker else { return }
        // Coalesced: scrolling through a hundred messages sends one marker, not a hundred.
        pendingReadMarker = max(pendingReadMarker, messageID)
        guard !isSendingReadMarker else { return }
        isSendingReadMarker = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isSendingReadMarker = false }
            // Drain, rather than send once: markers raised while a request was in flight
            // are the whole point of coalescing them, and the last one in a burst is the
            // one that matters. Sending only the marker this call started with left the
            // server behind by the rest of the burst until something else happened to ask
            // again — and if nothing did, the conversation stayed unread everywhere else.
            while self.pendingReadMarker > self.sentReadMarker {
                let marker = self.pendingReadMarker
                do throws(TalkError) {
                    try await self.session.chat.markRead(token: self.token, lastReadMessageID: marker)
                    self.sentReadMarker = marker
                } catch {
                    // Leave `pendingReadMarker` where it is: the next read event retries it.
                    Log.chat.warning("Couldn’t update the read marker: \(error.userMessage)")
                    return
                }
            }
        }
    }

    func markUnread() {
        guard capabilities.canMarkUnread else { return }
        userMarkedUnread = true
        conversation.unreadMessages = max(conversation.unreadMessages, 1)
        pushReadContext()
        let chat = session.chat
        let token = self.token
        Task { try? await chat.markUnread(token: token) }
    }

    private func computeFirstUnread() -> Int? {
        guard conversation.unreadMessages > 0, conversation.lastReadMessageID > 0 else { return nil }
        return timeline.messages.first {
            $0.messageID > conversation.lastReadMessageID && !session.account.isMe($0.actor)
        }?.messageID
    }

    /// Called when the user leaves the conversation, so the separator doesn't persist into
    /// the next visit.
    func clearUnreadSeparator() {
        guard firstUnreadMessageID != nil else { return }
        firstUnreadMessageID = nil
        rebuildRows()
    }

    // MARK: - Drafts

    var draftText: String = "" {
        didSet {
            scheduleDraftSave()
            refreshMentionQuery()
        }
    }

    /// Caret offset in the composer, reported by the text view. Mention autocomplete needs
    /// it to know which `@…` the user is inside.
    var caret: Int = 0 {
        didSet { refreshMentionQuery() }
    }

    /// Set to move the composer's caret after the model rewrites the text.
    var caretRequest: Int?

    // Not `private(set)`: the mention logic lives in ChatModel+Mentions.swift, and
    // `private` is file-scoped.
    var mentionQuery: MentionComposer.Query?
    var mentionSuggestions: [MentionSuggestion] = []
    var highlightedMentionIndex = 0
    @ObservationIgnored var mentionTask: Task<Void, Never>?
    /// Guards the text+caret rewrite when a suggestion is accepted. Without it, setting the
    /// text re-runs detection against the just-finished mention and the popover reopens on
    /// the name the user only just chose.
    @ObservationIgnored var isApplyingMention = false

    private var draftSaveTask: Task<Void, Never>?

    private func restoreDraft() async {
        guard let draft = await session.store.draft(token: token, accountID: session.account.id) else { return }
        draftText = draft.text
        if let replyTo = draft.replyToMessageID { replyingTo = timeline.message(id: replyTo) }
        if let editingID = draft.editingMessageID { editing = timeline.message(id: editingID) }
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            // Debounced: a draft save per keystroke would be a write amplification bug.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    /// Writes the draft and *waits* for it. Used on quit, where a fire-and-forget write
    /// would race the process going away.
    func flushDraft() async {
        draftSaveTask?.cancel()
        let draft = Draft(
            token: token,
            text: draftText,
            replyToMessageID: replyingTo?.messageID,
            editingMessageID: editing?.messageID
        )
        await session.store.save(draft: draft, accountID: session.account.id)
    }

    func saveDraftNow() {
        let draft = Draft(
            token: token,
            text: draftText,
            replyToMessageID: replyingTo?.messageID,
            editingMessageID: editing?.messageID
        )
        let store = session.store
        let accountID = session.account.id
        Task { await store.save(draft: draft, accountID: accountID) }
    }

    private func restorePendingMessages(from cached: [Message]) {
        var restoredAny = false
        for message in cached where message.deliveryState.isPending {
            // Anything still in flight when the app quit comes back as a failed send the
            // user can retry, rather than silently disappearing.
            var restored = message
            if case .sending = message.deliveryState {
                restored.deliveryState = .failed(reason: "Not sent")
            }
            timeline.addPending(restored)
            restoredAny = true
        }
        if restoredAny { rebuildRows() }
    }
}
