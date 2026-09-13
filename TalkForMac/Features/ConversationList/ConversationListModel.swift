import Foundation
import Observation

/// The sidebar's state.
///
/// Owns a ``ConversationIndex`` (the merge rules) and nothing else of consequence. Filter
/// text lives here too, because filtering is synchronous over an in-memory array and going
/// through an async boundary for it would only add latency to a keystroke.
@MainActor
@Observable
final class ConversationListModel {
    private(set) var index = ConversationIndex()
    /// The ⌘F filter string.
    var filterText = ""
    private(set) var isLoadingFirstTime = false

    private let session: Session
    private let notifications: NotificationController
    /// Tokens we have already notified about, so a re-fetch doesn't re-announce old news.
    private var announcedActivity: [String: Int] = [:]
    private var hasLoadedFromCache = false

    init(session: Session, notifications: NotificationController) {
        self.session = session
        self.notifications = notifications
    }

    var conversations: [Conversation] {
        index.filtered(by: filterText)
    }

    var totalUnreadCount: Int { index.totalUnreadCount }
    var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    subscript(token: String) -> Conversation? { index[token] }

    // MARK: - Loading

    /// Paints the sidebar from disk. This runs before any network call, which is the whole
    /// reason the app doesn't show a spinner at launch.
    func loadFromCache() async {
        isLoadingFirstTime = index.isEmpty
        let cached = await session.store.conversations(accountID: session.account.id)
        if !cached.isEmpty {
            index = ConversationIndex(cached)
            // Seed the "already announced" map so relaunching doesn't notify about
            // everything that was unread when the app quit.
            for conversation in cached {
                announcedActivity[conversation.token] = conversation.unreadMessages
            }
        }
        hasLoadedFromCache = true
        isLoadingFirstTime = false
    }

    func apply(_ result: ConversationListResult) async {
        let change = index.apply(result)
        guard !change.isEmpty else { return }

        await session.store.save(conversations: result.conversations, accountID: session.account.id)
        if !change.removed.isEmpty {
            await session.store.deleteConversations(tokens: change.removed, accountID: session.account.id)
        }

        var cursor = await session.store.syncState(accountID: session.account.id)
        cursor.conversationsModifiedSince = result.modifiedBefore ?? cursor.conversationsModifiedSince
        if !result.isIncremental { cursor.lastFullRefresh = Date() }
        await session.store.save(syncState: cursor, accountID: session.account.id)

        notifyAboutNewActivity(change)
    }

    /// Local echo for the read marker, so the unread dot disappears the moment the user
    /// reads something rather than on the next refresh.
    func markRead(token: String, upTo messageID: Int) {
        index.update(token: token) { conversation in
            guard messageID >= conversation.lastReadMessageID else { return }
            conversation.lastReadMessageID = messageID
            conversation.unreadMessages = 0
            conversation.unreadMention = false
            conversation.unreadMentionDirect = false
        }
        announcedActivity[token] = 0
        notifications.updateBadge(count: index.totalUnreadCount)
        persist(token: token)
    }

    // MARK: - Actions

    func toggleFavorite(_ conversation: Conversation) {
        let newValue = !conversation.isFavorite
        index.update(token: conversation.token) { $0.isFavorite = newValue }
        persist(token: conversation.token)

        Task {
            do {
                try await session.conversations.setFavorite(newValue, token: conversation.token)
            } catch {
                // Put it back: the sidebar must never disagree with the server for long.
                index.update(token: conversation.token) { $0.isFavorite = !newValue }
                Log.ui.warning("Couldn’t change favourite: \(error.userMessage)")
            }
        }
    }

    func setNotificationLevel(_ level: NotificationLevel, for conversation: Conversation) {
        let previous = conversation.notificationLevel
        index.update(token: conversation.token) { $0.notificationLevel = level }
        persist(token: conversation.token)

        Task {
            do {
                try await session.conversations.setNotificationLevel(level, token: conversation.token)
            } catch {
                index.update(token: conversation.token) { $0.notificationLevel = previous }
                Log.ui.warning("Couldn’t change notifications: \(error.userMessage)")
            }
        }
    }

    /// Mark as Unread. Requires the `chat-unread` capability; the menu item is hidden
    /// otherwise rather than failing when used.
    func markUnread(_ conversation: Conversation) {
        guard session.capabilitySnapshot.canMarkUnread else { return }
        index.update(token: conversation.token) { conversation in
            conversation.unreadMessages = max(conversation.unreadMessages, 1)
        }
        notifications.updateBadge(count: index.totalUnreadCount)

        Task {
            do {
                try await session.chat.markUnread(token: conversation.token)
            } catch {
                Log.ui.warning("Couldn’t mark as unread: \(error.userMessage)")
            }
        }
    }

    // MARK: - Keyboard navigation

    /// Next/previous conversation for ↓/↑ and ⌥⌘↓/↑, honouring the current filter.
    func conversation(after token: String?, offset: Int) -> Conversation? {
        let visible = conversations
        guard !visible.isEmpty else { return nil }
        guard let token, let current = visible.firstIndex(where: { $0.token == token }) else {
            return offset > 0 ? visible.first : visible.last
        }
        let next = current + offset
        guard visible.indices.contains(next) else { return nil }
        return visible[next]
    }

    /// The next conversation with something unread — ⌥⇧⌘↓ style "go to next unread".
    func nextUnread(after token: String?) -> Conversation? {
        let visible = conversations
        guard !visible.isEmpty else { return nil }
        let start = token.flatMap { current in visible.firstIndex { $0.token == current } } ?? -1
        let rotated = Array(visible[(start + 1)...]) + Array(visible[...max(start, 0)])
        return rotated.first { $0.hasUnread && $0.token != token }
    }

    // MARK: - Private

    private func notifyAboutNewActivity(_ change: ConversationIndex.Change) {
        for token in change.newActivity {
            guard let conversation = index[token] else { continue }
            let previous = announcedActivity[token] ?? 0
            announcedActivity[token] = conversation.unreadMessages
            guard conversation.unreadMessages > previous else { continue }
            notifications.notifyIfNeeded(about: conversation)
        }
        for token in change.updated where index[token]?.unreadMessages == 0 {
            announcedActivity[token] = 0
        }
    }

    private func persist(token: String) {
        guard let conversation = index[token] else { return }
        Task { await session.store.save(conversations: [conversation], accountID: session.account.id) }
    }
}
