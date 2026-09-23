import Foundation
import Testing
@testable import TalkCore

private func conversation(
    _ token: String,
    activity: TimeInterval,
    unread: Int = 0,
    favorite: Bool = false,
    mention: Bool = false,
    archived: Bool = false,
    level: NotificationLevel = .default,
    name: String? = nil
) -> Conversation {
    Conversation(
        token: token,
        type: .group,
        name: name ?? token,
        displayName: name ?? token,
        lastActivity: Date(timeIntervalSince1970: activity),
        isFavorite: favorite,
        isArchived: archived,
        notificationLevel: level,
        unreadMessages: unread,
        unreadMention: mention
    )
}

private func result(_ conversations: [Conversation], incremental: Bool) -> ConversationListResult {
    ConversationListResult(
        conversations: conversations,
        modifiedBefore: nil,
        talkHash: nil,
        isIncremental: incremental
    )
}

@Suite("Conversation index")
struct ConversationIndexTests {
    @Test("A full refresh removes conversations the server no longer lists")
    func fullRefreshRemoves() {
        var index = ConversationIndex([conversation("a", activity: 10), conversation("b", activity: 9)])
        let change = index.apply(result([conversation("a", activity: 11)], incremental: false))

        #expect(index.conversations.map(\.token) == ["a"])
        #expect(change.removed == ["b"])
    }

    @Test("An incremental refresh never removes, because modifiedSince can't express removal")
    func incrementalNeverRemoves() {
        var index = ConversationIndex([conversation("a", activity: 10), conversation("b", activity: 9)])
        let change = index.apply(result([conversation("a", activity: 11)], incremental: true))

        #expect(index.conversations.map(\.token).sorted() == ["a", "b"])
        #expect(change.removed.isEmpty)
        #expect(change.updated == ["a"])
    }

    @Test("An incremental refresh adds conversations it hasn't seen")
    func incrementalAdds() {
        var index = ConversationIndex([conversation("a", activity: 10)])
        let change = index.apply(result([conversation("new", activity: 20, unread: 2)], incremental: true))

        #expect(index.conversations.map(\.token) == ["new", "a"])
        #expect(change.inserted == ["new"])
        #expect(change.newActivity == ["new"])
    }

    @Test("Rising unread counts are reported, so notifications have something to fire on")
    func detectsNewActivity() {
        var index = ConversationIndex([conversation("a", activity: 10, unread: 1)])

        let more = index.apply(result([conversation("a", activity: 11, unread: 4)], incremental: true))
        #expect(more.newActivity == ["a"])

        // Reading it elsewhere lowers the count — that is not new activity.
        let fewer = index.apply(result([conversation("a", activity: 12, unread: 0)], incremental: true))
        #expect(fewer.newActivity.isEmpty)
        #expect(fewer.updated == ["a"])
    }

    @Test("An unchanged conversation produces no change at all")
    func noopMerge() {
        let existing = conversation("a", activity: 10, unread: 3)
        var index = ConversationIndex([existing])
        #expect(index.apply(result([existing], incremental: true)).isEmpty)
    }

    @Test("Sorting stays correct as activity moves")
    func resortsOnUpdate() {
        var index = ConversationIndex([conversation("a", activity: 30), conversation("b", activity: 20)])
        index.apply(result([conversation("b", activity: 40)], incremental: true))
        #expect(index.conversations.map(\.token) == ["b", "a"])
    }

    @Test("Dock badge counts unread messages but ignores muted and archived conversations")
    func unreadTotals() {
        let index = ConversationIndex([
            conversation("a", activity: 10, unread: 3),
            conversation("b", activity: 9, unread: 5, level: .never),
            conversation("c", activity: 8, unread: 7, archived: true),
            conversation("d", activity: 7, unread: 2, mention: true)
        ])
        #expect(index.totalUnreadCount == 5)
        #expect(index.hasUnreadMention)
    }

    @Test("Filtering matches names and last-message text, and is case-insensitive")
    func filtering() {
        var withMessage = conversation("x", activity: 10, name: "Design review")
        withMessage.lastMessage = Message(
            messageID: 1, token: "x", actor: MessageActor(kind: .users, id: "bob"),
            timestamp: .now, text: "the quarterly Budget is ready"
        )
        let index = ConversationIndex([withMessage, conversation("y", activity: 9, name: "Ops")])

        #expect(index.filtered(by: "design").map(\.token) == ["x"])
        #expect(index.filtered(by: "DESIGN").map(\.token) == ["x"])
        #expect(index.filtered(by: "budget").map(\.token) == ["x"])
        #expect(index.filtered(by: "  ").count == 2)
        #expect(index.filtered(by: "nothing").isEmpty)
    }

    @Test("Filtering ignores diacritics, the way the Finder's search field does")
    func filteringIgnoresDiacritics() {
        let index = ConversationIndex([
            conversation("x", activity: 10, name: "Café Jérôme"),
            conversation("y", activity: 9, name: "Ops")
        ])

        #expect(index.filtered(by: "café").map(\.token) == ["x"])
        #expect(index.filtered(by: "cafe").map(\.token) == ["x"])
        #expect(index.filtered(by: "JEROME").map(\.token) == ["x"])
    }

    @Test("Optimistic local updates apply immediately and keep the order correct")
    func optimisticUpdate() {
        var index = ConversationIndex([conversation("a", activity: 30), conversation("b", activity: 20)])
        index.update(token: "b") { $0.isFavorite = true }

        #expect(index.conversations.map(\.token) == ["b", "a"])
        #expect(index["b"]?.isFavorite == true)
    }
}

@Suite("Backoff")
struct BackoffTests {
    @Test("Delays grow exponentially and stop at the ceiling")
    func exponentialGrowth() {
        let backoff = Backoff(base: 1, maximum: 30, multiplier: 2, jitter: 0)
        #expect(backoff.delay(forAttempt: 1) == 1)
        #expect(backoff.delay(forAttempt: 2) == 2)
        #expect(backoff.delay(forAttempt: 3) == 4)
        #expect(backoff.delay(forAttempt: 6) == 30)
        #expect(backoff.delay(forAttempt: 20) == 30)
        #expect(backoff.delay(forAttempt: 0) == 0)
    }

    @Test("Jitter stays within its stated bounds")
    func jitterBounds() {
        let backoff = Backoff(base: 4, maximum: 60, multiplier: 2, jitter: 0.25)
        #expect(backoff.delay(forAttempt: 1, random: { $0.lowerBound }) == 3)
        #expect(backoff.delay(forAttempt: 1, random: { $0.upperBound }) == 5)
        for attempt in 1...10 {
            let delay = backoff.delay(forAttempt: attempt)
            #expect(delay >= 0)
            #expect(delay <= 60 * 1.25)
        }
    }

    @Test("The server's Retry-After wins over our own schedule")
    func honoursRetryAfter() {
        let backoff = Backoff(base: 1, maximum: 60, jitter: 0)
        #expect(backoff.delay(forAttempt: 1, after: .rateLimited(retryAfter: 42)) == 42)
        #expect(backoff.delay(forAttempt: 1, after: .maintenanceMode) == 60)
        #expect(backoff.delay(forAttempt: 3, after: .timedOut) == 4)
    }
}

@Suite("Read state policy")
struct ReadStatePolicyTests {
    private var readable: ReadStateContext {
        ReadStateContext(
            isSelected: true, isApplicationActive: true,
            isWindowKey: true, isScrolledToLatest: true, userMarkedUnread: false
        )
    }

    @Test("All four conditions must hold")
    func requiresEveryCondition() {
        #expect(ReadStatePolicy.canMarkRead(readable))

        var notSelected = readable; notSelected.isSelected = false
        #expect(ReadStatePolicy.canMarkRead(notSelected) == false)

        var background = readable; background.isApplicationActive = false
        #expect(ReadStatePolicy.canMarkRead(background) == false)

        var notKey = readable; notKey.isWindowKey = false
        #expect(ReadStatePolicy.canMarkRead(notKey) == false)

        var scrolledUp = readable; scrolledUp.isScrolledToLatest = false
        #expect(ReadStatePolicy.canMarkRead(scrolledUp) == false)
    }

    @Test("Mark as Unread survives the conversation still being selected")
    func explicitUnreadWins() {
        var context = readable
        context.userMarkedUnread = true
        #expect(ReadStatePolicy.canMarkRead(context) == false)
        #expect(ReadStatePolicy.readMarker(context: context, latestVisibleMessageID: 99, lastReadMessageID: 1) == nil)
    }

    @Test("The marker only ever moves forward")
    func markerMovesForwardOnly() {
        #expect(ReadStatePolicy.readMarker(context: readable, latestVisibleMessageID: 100, lastReadMessageID: 90) == 100)
        #expect(ReadStatePolicy.readMarker(context: readable, latestVisibleMessageID: 90, lastReadMessageID: 90) == nil)
        #expect(ReadStatePolicy.readMarker(context: readable, latestVisibleMessageID: 80, lastReadMessageID: 90) == nil)
    }

    @Test("Background polling never asks the server to move the read marker")
    func backgroundPollsDoNotMarkRead() {
        #expect(ReadStatePolicy.setReadMarkerOnPoll(ReadStateContext()) == false)
        var visible = ReadStateContext(); visible.isSelected = true
        #expect(ReadStatePolicy.setReadMarkerOnPoll(visible) == false)
        #expect(ReadStatePolicy.setReadMarkerOnPoll(readable))
    }
}

@Suite("Sidebar sections")
struct SidebarSectionTests {
    private func make(_ token: String, favorite: Bool = false, archived: Bool = false) -> Conversation {
        Conversation(
            token: token,
            displayName: token,
            lastActivity: Date(timeIntervalSince1970: 1000),
            isFavorite: favorite,
            isArchived: archived
        )
    }

    @Test("Favourites, then everything else, then the archive")
    func grouping() {
        let sections = ConversationIndex.sections(for: [
            make("fav", favorite: true),
            make("normal"),
            make("old", archived: true)
        ])

        #expect(sections.map(\.section) == [.favorites, .conversations, .archived])
        #expect(sections[0].items.map(\.token) == ["fav"])
        #expect(sections[2].items.map(\.token) == ["old"])
        // Identifiable, because SwiftUI's ForEach needs a key path and Swift has none into
        // tuple elements — which is the bug this struct exists to prevent.
        #expect(sections[0].id == "favorites")
    }

    @Test("Empty sections don't get a heading")
    func dropsEmptySections() {
        let sections = ConversationIndex.sections(for: [make("a"), make("b")])
        #expect(sections.map(\.section) == [.conversations])
    }

    @Test("An archived favourite is archived — the archive wins")
    func archiveWins() {
        let sections = ConversationIndex.sections(for: [make("x", favorite: true, archived: true)])
        #expect(sections.map(\.section) == [.archived])
    }

    @Test("The archive is hidden from the list but not from search")
    func searchReachesTheArchive() {
        let index = ConversationIndex([
            Conversation(token: "a", displayName: "Budget talk"),
            Conversation(token: "b", displayName: "Budget archive", isArchived: true)
        ])

        #expect(index.visibleConversations.map(\.token) == ["a"])
        #expect(index.filtered(by: "").map(\.token) == ["a"])
        #expect(index.filtered(by: "budget").map(\.token).sorted() == ["a", "b"])
        #expect(index.archivedCount == 1)
    }
}

@Suite("Favourite order")
struct FavoriteOrderTests {
    private func favorite(_ token: String) -> Conversation {
        Conversation(token: token, displayName: token, isFavorite: true)
    }

    @Test("Favourites keep the arranged order, and new ones follow")
    func arranged() {
        let incoming = ["c", "new", "a", "b"].map(favorite)
        #expect(ConversationIndex.arrange(favorites: incoming, by: ["a", "b", "c"]).map(\.token) == ["a", "b", "c", "new"])
    }

    @Test("Dropping onto another's place takes it, forwards and backwards")
    func move() {
        #expect(ConversationIndex.move("a", onto: "c", in: ["a", "b", "c", "d"]) == ["b", "c", "a", "d"])
        #expect(ConversationIndex.move("d", onto: "b", in: ["a", "b", "c", "d"]) == ["a", "d", "b", "c"])
        #expect(ConversationIndex.move("a", onto: "a", in: ["a", "b"]) == ["a", "b"])
    }
}
