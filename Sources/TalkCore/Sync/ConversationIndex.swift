import Foundation

/// The sidebar's model: every known conversation, sorted, with the merge rules for
/// incremental and full refreshes.
///
/// The distinction matters and is easy to get wrong: `modifiedSince` cannot express a
/// conversation you were removed from, so an incremental result may only ever *add or
/// update*. Only a full refresh is allowed to delete.
struct ConversationIndex: Sendable, Equatable {
    private(set) var conversations: [Conversation] = []
    private var indexByToken: [String: Int] = [:]

    init(_ conversations: [Conversation] = []) {
        self.conversations = conversations.sorted(by: Conversation.sidebarSort)
        reindex()
    }

    struct Change: Sendable, Equatable {
        var inserted: [String] = []
        var updated: [String] = []
        var removed: [String] = []
        /// Tokens whose unread count went *up* — the trigger for notifications.
        var newActivity: [String] = []

        var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && removed.isEmpty }
    }

    // MARK: - Queries

    subscript(token: String) -> Conversation? {
        indexByToken[token].map { conversations[$0] }
    }

    var isEmpty: Bool { conversations.isEmpty }
    var count: Int { conversations.count }

    /// Excludes archived conversations, which belong in their own section.
    var visibleConversations: [Conversation] {
        conversations.filter { !$0.isArchived }
    }

    var totalUnreadCount: Int {
        visibleConversations
            .filter { $0.notificationLevel != .never }
            .reduce(0) { $0 + $1.unreadMessages }
    }

    var hasUnreadMention: Bool {
        visibleConversations.contains { $0.unreadMention && $0.unreadMessages > 0 }
    }

    /// The most recent `lastActivity`, which is what the next incremental fetch asks from —
    /// used only as a fallback when the server didn't send `X-Nextcloud-Talk-Modified-Before`.
    var latestActivityTimestamp: Int {
        Int(conversations.map(\.lastActivity).max()?.timeIntervalSince1970 ?? 0)
    }

    // MARK: - Merging

    @discardableResult
    mutating func apply(_ result: ConversationListResult) -> Change {
        var change = Change()

        for conversation in result.conversations {
            if let index = indexByToken[conversation.token] {
                let existing = conversations[index]
                if existing != conversation {
                    if conversation.unreadMessages > existing.unreadMessages {
                        change.newActivity.append(conversation.token)
                    }
                    conversations[index] = conversation
                    change.updated.append(conversation.token)
                }
            } else {
                conversations.append(conversation)
                change.inserted.append(conversation.token)
                if conversation.unreadMessages > 0 { change.newActivity.append(conversation.token) }
            }
        }

        if !result.isIncremental {
            // A full refresh is the only thing that can tell us a conversation is gone:
            // deletions and disinvites are invisible to `modifiedSince`.
            let present = Set(result.conversations.map(\.token))
            let removed = conversations.map(\.token).filter { !present.contains($0) }
            if !removed.isEmpty {
                let removedSet = Set(removed)
                conversations.removeAll { removedSet.contains($0.token) }
                change.removed = removed
            }
        }

        if !change.isEmpty { resort() }
        return change
    }

    /// Local, optimistic update — used when the user favourites, mutes, or reads something
    /// and we don't want to wait for a round trip.
    mutating func update(token: String, _ transform: (inout Conversation) -> Void) {
        guard let index = indexByToken[token] else { return }
        transform(&conversations[index])
        resort()
    }

    mutating func remove(token: String) {
        conversations.removeAll { $0.token == token }
        reindex()
    }

    // MARK: - Filtering

    /// The ⌘F filter. Deliberately simple and synchronous: it runs on every keystroke over
    /// an in-memory array, and anything cleverer would be slower than it is useful.
    func filtered(by query: String) -> [Conversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleConversations }

        return visibleConversations.filter { conversation in
            if conversation.displayName.localizedCaseInsensitiveContains(query) { return true }
            if conversation.name.localizedCaseInsensitiveContains(query) { return true }
            if conversation.description.localizedCaseInsensitiveContains(query) { return true }
            if let text = conversation.lastMessage?.text, text.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    private mutating func resort() {
        conversations.sort(by: Conversation.sidebarSort)
        reindex()
    }

    private mutating func reindex() {
        indexByToken.removeAll(keepingCapacity: true)
        indexByToken.reserveCapacity(conversations.count)
        for index in conversations.indices {
            indexByToken[conversations[index].token] = index
        }
    }
}
