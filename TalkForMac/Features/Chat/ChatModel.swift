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
    /// The transcript's display list. Rebuilt when the timeline changes — never per render.
    private(set) var rows: [ChatRow] = []
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

    init(
        session: Session,
        conversation: Conversation,
        readContext: @escaping @MainActor () -> ReadStateContext,
        onReadMarker: @escaping @MainActor (String, Int) -> Void
    ) {
        self.session = session
        self.conversation = conversation
        self.readContext = readContext
        self.onReadMarker = onReadMarker
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
    }

    /// Async on purpose. The long-poll engine is shared between conversations, so the
    /// previous conversation's stop has to *complete* before the next one starts — otherwise
    /// a stop scheduled from the old model can land after the new model's activate and kill
    /// the subscription that just opened.
    func deactivate() async {
        syncTask?.cancel()
        syncTask = nil
        saveDraftNow()
        await session.chatSync.stop()
    }

    func applicationDidBecomeActive() async {
        pushReadContext()
        markReadIfPossible()
    }

    func reconnect() async {
        guard syncTask == nil || syncState == .offline else { return }
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

        if firstUnreadMessageID == nil, !change.appendedAtEnd {
            firstUnreadMessageID = computeFirstUnread()
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

        do {
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

    private func sendReadMarker(_ messageID: Int) {
        guard capabilities.canSetReadMarker else { return }
        // Coalesced: scrolling through a hundred messages sends one marker, not a hundred.
        pendingReadMarker = max(pendingReadMarker, messageID)
        guard !isSendingReadMarker else { return }
        isSendingReadMarker = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isSendingReadMarker = false }
            let marker = self.pendingReadMarker
            do {
                try await self.session.chat.markRead(token: self.token, lastReadMessageID: marker)
            } catch {
                Log.chat.warning("Couldn’t update the read marker: \(error.userMessage)")
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

    private(set) var mentionQuery: MentionComposer.Query?
    private(set) var mentionSuggestions: [MentionSuggestion] = []
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
        for message in cached where message.deliveryState.isPending {
            // Anything still in flight when the app quit comes back as a failed send the
            // user can retry, rather than silently disappearing.
            var restored = message
            if case .sending = message.deliveryState {
                restored.deliveryState = .failed(reason: "Not sent")
            }
            timeline.addPending(restored)
            rebuildRows()
        }
    }
}
