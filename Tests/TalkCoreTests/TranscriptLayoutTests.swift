import Foundation
import Testing
@testable import TalkCore

private let token = "a1b2c3d4"
private let noon = Date(timeIntervalSince1970: 1_757_678_400)   // 2025-09-12 12:00 UTC

private func message(
    _ id: Int,
    actor: String = "bob",
    at offset: TimeInterval = 0,
    text: String = "hello",
    system: String = ""
) -> Message {
    Message(
        messageID: id,
        token: token,
        actor: MessageActor(kind: .users, id: actor, displayName: actor.capitalized),
        timestamp: noon.addingTimeInterval(offset),
        kind: system.isEmpty ? .comment : .system,
        systemMessage: system,
        text: text
    )
}

@Suite("Transcript layout")
struct TranscriptLayoutTests {
    // MARK: - Grouping

    @Test("Consecutive messages from one person collapse into a run")
    func groupsConsecutiveMessages() {
        let first = message(1, at: 0)
        let second = message(2, at: 30)
        let third = message(3, at: 60)

        #expect(MessageGroupContext.between(previous: nil, current: first).showsHeader)
        #expect(MessageGroupContext.between(previous: first, current: second).showsHeader == false)
        #expect(MessageGroupContext.between(previous: second, current: third).showsAvatar == false)
    }

    @Test("A different sender always starts a new group")
    func differentSenderBreaksGroup() {
        let mine = message(1, actor: "alice")
        let theirs = message(2, actor: "bob", at: 10)
        #expect(MessageGroupContext.between(previous: mine, current: theirs).showsHeader)
    }

    @Test("A long gap starts a new group, so the time is visible again")
    func timeGapBreaksGroup() {
        let first = message(1, at: 0)
        let later = message(2, at: MessageGroupContext.groupingWindow + 1)
        #expect(MessageGroupContext.between(previous: first, current: later).showsHeader)
    }

    @Test("System messages neither group nor break the run around them visually")
    func systemMessages() {
        let system = message(2, system: "user_added")
        let group = MessageGroupContext.between(previous: message(1), current: system)
        #expect(group.showsHeader == false)
        #expect(group.showsAvatar == false)

        // The message after a system message starts fresh.
        #expect(MessageGroupContext.between(previous: system, current: message(3)).showsHeader)
    }

    // MARK: - Row building

    @Test("A day separator is inserted where the date changes, and only there")
    func daySeparators() {
        let rows = ChatRow.build(
            messages: [
                message(1, at: 0),
                message(2, at: 60),
                message(3, at: 24 * 3600),        // next day
                message(4, at: 24 * 3600 + 60)
            ],
            firstUnreadMessageID: nil
        )

        let separators = rows.filter { if case .daySeparator = $0.kind { return true } else { return false } }
        #expect(separators.count == 2)
        #expect(rows.count == 6)
        // The first message after a day break isn't grouped with yesterday's.
        if case .message(_, let group) = rows[4].kind { #expect(group.showsHeader) } else { Issue.record("expected message") }
    }

    @Test("The unread marker lands above the first unread message, exactly once")
    func unreadSeparator() {
        let rows = ChatRow.build(
            messages: [message(1), message(2, at: 10), message(3, at: 20), message(4, at: 30)],
            firstUnreadMessageID: 3
        )

        let markerIndex = try? #require(rows.firstIndex { $0.isUnreadSeparator })
        #expect(rows.filter(\.isUnreadSeparator).count == 1)
        if let markerIndex {
            #expect(rows[markerIndex + 1].message?.messageID == 3)
        }
    }

    @Test("No unread marker when there's nothing unread")
    func noUnreadSeparator() {
        let rows = ChatRow.build(messages: [message(1), message(2, at: 10)], firstUnreadMessageID: nil)
        #expect(rows.contains(where: \.isUnreadSeparator) == false)
    }

    @Test("Cache-only system messages never reach the transcript")
    func hidesInvisibleSystemMessages() {
        let rows = ChatRow.build(
            messages: [
                message(1),
                message(2, at: 10, system: "message_deleted"),
                message(3, at: 20, system: "reaction"),
                message(4, at: 30, system: "user_added"),
                message(5, at: 40)
            ],
            firstUnreadMessageID: nil
        )

        let ids = rows.compactMap { $0.message?.messageID }
        #expect(ids == [1, 4, 5])
    }

    @Test("Row identities are stable, so SwiftUI doesn't rebuild the transcript")
    func stableIdentities() {
        let messages = [message(1), message(2, at: 10)]
        let first = ChatRow.build(messages: messages, firstUnreadMessageID: nil)
        let second = ChatRow.build(messages: messages, firstUnreadMessageID: nil)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)   // no duplicates
    }

    @Test("An empty conversation produces no rows at all")
    func emptyTranscript() {
        #expect(ChatRow.build(messages: [], firstUnreadMessageID: nil).isEmpty)
    }

    // MARK: - Previews

    @Test("A group conversation's preview names the sender; a one-to-one doesn't")
    func previewSenderPrefix() {
        var group = Conversation(token: "g", type: .group, displayName: "Design")
        group.lastMessage = message(1, actor: "bob", text: "ready?")
        #expect(ConversationPreview.text(for: group) == "Bob: ready?")

        var direct = Conversation(token: "d", type: .oneToOne, name: "bob", displayName: "Bob")
        direct.lastMessage = message(1, actor: "bob", text: "ready?")
        #expect(ConversationPreview.text(for: direct) == "ready?")
    }

    @Test("A conversation with no messages says so, and Note to Self says something friendlier")
    func emptyPreview() {
        #expect(ConversationPreview.text(for: Conversation(token: "x", type: .group)) == "No messages yet")
        #expect(ConversationPreview.text(for: Conversation(token: "n", type: .noteToSelf)) == "Notes to yourself")
    }

    @Test("Previews render placeholders, never raw protocol text")
    func previewResolvesPlaceholders() {
        var conversation = Conversation(token: "g", type: .group)
        var message = message(1, actor: "bob", text: "Look at {file}")
        message.parameters = ["file": RichObject(type: .file, id: "1", name: "budget.xlsx")]
        conversation.lastMessage = message

        let preview = ConversationPreview.text(for: conversation)
        #expect(preview == "Bob: Look at budget.xlsx")
        #expect(!preview.contains("{file}"))
    }

    @Test("A system message preview isn't prefixed with the actor's name twice")
    func systemMessagePreview() {
        var conversation = Conversation(token: "g", type: .group)
        var system = message(1, actor: "carol", system: "call_started")
        system.text = "{actor} started a call"
        system.parameters = ["actor": RichObject(type: .user, id: "carol", name: "Carol")]
        conversation.lastMessage = system

        #expect(ConversationPreview.text(for: conversation) == "Carol started a call")
    }

    // MARK: - Timestamps

    // Pinned, because the shapes asserted below are en_US ones. Unpinned, this passes on
    // Linux CI and fails on a Danish Mac, which renders 13.00 rather than 1:00 PM.
    private let enUS = Locale(identifier: "en_US")

    @Test("Sidebar timestamps are relative and compact")
    func sidebarTimestamps() {
        let calendar = Calendar(identifier: .gregorian)
        let now = noon

        func sidebar(_ date: Date) -> String {
            RelativeTimestamp.sidebar(date, now: now, calendar: calendar, locale: enUS)
        }

        #expect(sidebar(now.addingTimeInterval(-3600)).contains(":"))
        #expect(sidebar(now.addingTimeInterval(-24 * 3600)) == "Yesterday")

        let threeDaysAgo = sidebar(now.addingTimeInterval(-3 * 24 * 3600))
        #expect(threeDaysAgo.count <= 4)          // an abbreviated weekday

        let longAgo = sidebar(now.addingTimeInterval(-60 * 24 * 3600))
        #expect(longAgo.contains("/") || longAgo.contains("."))

        // A conversation that has never had activity shows nothing rather than 1970.
        #expect(sidebar(Date(timeIntervalSince1970: 0)) == "")
    }

    @Test("Sidebar timestamps follow the locale rather than hardcoding US conventions")
    func sidebarTimestampsAreLocalised() {
        let calendar = Calendar(identifier: .gregorian)
        let anHourAgo = noon.addingTimeInterval(-3600)

        let danish = RelativeTimestamp.sidebar(
            anHourAgo, now: noon, calendar: calendar, locale: Locale(identifier: "da_DK")
        )
        // Danish writes the time with a full stop and on a 24-hour clock.
        #expect(danish.contains("."))
        #expect(!danish.contains("AM") && !danish.contains("PM"))
    }

    @Test("Day separators say Today and Yesterday")
    func daySeparatorLabels() {
        let calendar = Calendar(identifier: .gregorian)
        #expect(RelativeTimestamp.daySeparator(noon, now: noon, calendar: calendar, locale: enUS) == "Today")
        #expect(RelativeTimestamp.daySeparator(
            noon.addingTimeInterval(-24 * 3600), now: noon, calendar: calendar, locale: enUS
        ) == "Yesterday")
    }
}

@Suite("Message search")
struct MessageSearchTests {
    private let parser = MessageContentParser(currentUserID: "alice")

    private func message(_ id: Int, _ text: String, actor: String = "bob", parameters: [String: RichObject] = [:]) -> Message {
        Message(
            messageID: id,
            token: "tok",
            actor: MessageActor(kind: .users, id: actor, displayName: actor.capitalized),
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_757_000_000 + id)),
            text: text,
            parameters: parameters
        )
    }

    @Test("Finds matches newest first")
    func newestFirst() {
        let matches = MessageSearch.matches(
            in: [message(1, "budget draft"), message(2, "the budget again"), message(3, "unrelated")],
            query: "budget",
            parser: parser
        )
        #expect(matches.map(\.messageID) == [2, 1])
    }

    @Test("Ignores case and accents")
    func caseAndAccents() {
        let matches = MessageSearch.matches(in: [message(1, "Café plans")], query: "cafe", parser: parser)
        #expect(matches.count == 1)
    }

    @Test("Searches what's on screen, not the raw protocol text")
    func searchesRenderedText() {
        // A file share's text is "{file}" — searching for the filename must still find it.
        let fileMessage = message(1, "{file}", parameters: [
            "file": RichObject(type: .file, id: "1", name: "budget-2026.xlsx")
        ])
        #expect(MessageSearch.matches(in: [fileMessage], query: "budget", parser: parser).count == 1)
        #expect(MessageSearch.matches(in: [fileMessage], query: "{file}", parser: parser).isEmpty)

        // Likewise a mention: the raw text has a placeholder, the rendered text has the name.
        let mention = message(2, "ping {mention-user1}", parameters: [
            "mention-user1": RichObject(type: .user, id: "carol", name: "Carol Cortez")
        ])
        #expect(MessageSearch.matches(in: [mention], query: "carol", parser: parser).count == 1)
    }

    @Test("Finds by author as well as by content")
    func searchesAuthor() {
        #expect(MessageSearch.matches(in: [message(1, "hello", actor: "carol")], query: "carol", parser: parser).count == 1)
    }

    @Test("A one-character query returns nothing rather than everything")
    func minimumLength() {
        #expect(MessageSearch.matches(in: [message(1, "anything")], query: "a", parser: parser).isEmpty)
        #expect(MessageSearch.matches(in: [message(1, "anything")], query: "  ", parser: parser).isEmpty)
    }

    @Test("Deleted and cache-only messages never appear in results")
    func skipsInvisible() {
        var deleted = message(1, "secret plans")
        deleted.isDeleted = true
        var system = message(2, "secret plans")
        system.kind = .system
        system.systemMessage = "message_deleted"

        #expect(MessageSearch.matches(in: [deleted, system], query: "secret", parser: parser).isEmpty)
    }

    @Test("Results are capped so a common word can't build a huge list")
    func respectsLimit() {
        let many = (1...500).map { message($0, "budget line \($0)") }
        #expect(MessageSearch.matches(in: many, query: "budget", parser: parser, limit: 50).count == 50)
    }

    @Test("Highlight ranges come back for the matched part")
    func highlightRange() throws {
        let range = try #require(MessageSearch.highlightRange(of: "bud", in: "the BUDGET line"))
        #expect("the BUDGET line"[range] == "BUD")
    }
}
