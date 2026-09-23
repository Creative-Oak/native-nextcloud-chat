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

    /// One pass, no intermediate arrays: this is read on every badge update and on every
    /// sidebar render.
    var totalUnreadCount: Int {
        conversations.reduce(0) { total, conversation in
            guard !conversation.isArchived, !conversation.isBreakoutRoom, conversation.notificationLevel != .never else { return total }
            return total + conversation.unreadMessages
        }
    }

    var hasUnreadMention: Bool {
        conversations.contains { !$0.isArchived && !$0.isBreakoutRoom && $0.unreadMention && $0.unreadMessages > 0 }
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

    // MARK: - Sections

    /// The sidebar's groups. Favourites first because the user said they matter, then
    /// everything else by activity, then archived out of the way at the bottom.
    enum Section: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// One of the user's own tags, whose name heads it.
        case favorites, tagged, conversations, archived
        var id: String { rawValue }

        var title: String {
            switch self {
            case .favorites: "Favourites"
            case .tagged: "Tagged"
            case .conversations: "Conversations"
            case .archived: "Archived"
            }
        }

        var symbolName: String {
            switch self {
            case .favorites: "star"
            case .tagged: "tag"
            case .conversations: "bubble.left.and.bubble.right"
            case .archived: "archivebox"
            }
        }
    }

    /// A section and its rows. A struct rather than a tuple because Swift has no key paths
    /// into tuple elements, and `ForEach(_:id:)` needs one.
    struct SectionGroup: Sendable, Identifiable, Equatable {
        /// One per tag, and one for each of the other kinds.
        var id: String { tag.map { "tag-\($0.id)" } ?? section.rawValue }
        var section: Section
        var items: [Conversation]
        /// The tag a `.tagged` section is; on `.conversations`, Talk's built-in tag for
        /// everything untagged, when there is one — its name and whether it's folded.
        var tag: ConversationTag?

        init(section: Section, items: [Conversation], tag: ConversationTag? = nil) {
            self.section = section
            self.items = items
            self.tag = tag
        }

        /// What heads it: a tag's name, or the section's own.
        var title: String { tag?.name ?? section.title }
    }

    /// Groups the (already filtered) conversations for display. Empty sections are dropped,
    /// so a user with no favourites never sees an empty "Favourites" heading. Breakout rooms
    /// aren't listed — as in Talk's own apps, they're reached from the conversation they
    /// belong to — nor counted in the unread totals above, where an unread one would be a
    /// badge nothing in the sidebar could clear.
    ///
    /// With the user's own tags (cap `conversation-tags`), everything that isn't a favourite
    /// is sorted into them, a section each in the user's order, and whatever has none goes
    /// under Talk's built-in tag for the rest — as Talk's web app lays it out. Something
    /// with two tags is in both. Favourites stay only among the faces at the top.
    static func sections(for conversations: [Conversation], tags: [ConversationTag] = []) -> [SectionGroup] {
        var favorites: [Conversation] = []
        var regular: [Conversation] = []
        var archived: [Conversation] = []
        let custom = tags.filter { $0.kind == .custom }
        let known = Set(custom.map(\.id))
        var tagged: [String: [Conversation]] = [:]

        for conversation in conversations where !conversation.isBreakoutRoom {
            if conversation.isArchived { archived.append(conversation); continue }
            // A tagged favourite is in both places, as Talk's web app shows it: among the
            // faces, and in its tags' sections.
            let mine = conversation.tagIDs.filter(known.contains)
            for id in mine { tagged[id, default: []].append(conversation) }
            if conversation.isFavorite {
                favorites.append(conversation)
            } else if mine.isEmpty {
                regular.append(conversation)
            }
        }

        var groups = [SectionGroup(section: .favorites, items: favorites)]
        groups += custom.map { SectionGroup(section: .tagged, items: tagged[$0.id] ?? [], tag: $0) }
        groups.append(SectionGroup(section: .conversations, items: regular, tag: tags.first { $0.kind == .other }))
        groups.append(SectionGroup(section: .archived, items: archived))
        return groups.filter { !$0.items.isEmpty }
    }

    /// Everything, including archived — used when the sidebar is showing the archive.
    var allConversations: [Conversation] { conversations }

    var archivedCount: Int { conversations.count { $0.isArchived } }

    // MARK: - Filtering

    /// The ⌘F filter. Deliberately simple and synchronous: it runs on every keystroke over
    /// an in-memory array, and anything cleverer would be slower than it is useful.
    func filtered(by query: String) -> [Conversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // With no query, the archive stays out of the way. With one, it is searched too:
        // hiding a conversation from a list is not the same as hiding it from search.
        guard !query.isEmpty else { return visibleConversations }

        return conversations.filter { conversation in
            // `localizedStandardContains` rather than a case-insensitive compare: it is what
            // the Finder searches with, so it also ignores diacritics and width, and typing
            // "jerome" finds Jérôme. (A letter that is its own, such as ø, is still its own —
            // folding is of diacritics, not of the alphabet.)
            if conversation.displayName.localizedStandardContains(query) { return true }
            if conversation.name.localizedStandardContains(query) { return true }
            if conversation.description.localizedStandardContains(query) { return true }
            if let text = conversation.lastMessage?.text, text.localizedStandardContains(query) { return true }
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

    /// Favourites in the order the user arranged them, rather than by activity: a face that
    /// jumps along the row whenever someone writes is one you can't find by where it is.
    /// Tokens in `order` come first, in that order; favourites not in it yet follow, in the
    /// order they arrive.
    static func arrange(favorites: [Conversation], by order: [String]) -> [Conversation] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = favorites.filter { position[$0.token] != nil }.sorted { position[$0.token]! < position[$1.token]! }
        let unplaced = favorites.filter { position[$0.token] == nil }
        return placed + unplaced
    }

    /// The order after dragging `moved` onto `target`: it takes the target's place, and the
    /// rest shuffle along.
    static func move(_ moved: String, onto target: String, in order: [String]) -> [String] {
        guard moved != target, order.contains(moved), let targetIndex = order.firstIndex(of: target) else { return order }
        let movingForward = (order.firstIndex(of: moved) ?? 0) < targetIndex
        var result = order.filter { $0 != moved }
        let insertAt = (result.firstIndex(of: target) ?? result.count) + (movingForward ? 1 : 0)
        result.insert(moved, at: min(insertAt, result.count))
        return result
    }
}

