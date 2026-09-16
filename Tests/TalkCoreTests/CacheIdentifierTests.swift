import Foundation
import SwiftData
import Testing
@testable import TalkCore

/// The cache's row keys: that different rows never share one, and that rows written under
/// the old keys are still found.
@Suite("Cache row keys")
struct CacheIdentifierTests {
    private let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    private func message(_ id: Int, token: String, localID: String) -> Message {
        Message(
            messageID: id,
            localID: localID,
            token: token,
            actor: MessageActor(kind: .users, id: "bob", displayName: "Bob"),
            timestamp: epoch,
            text: "hello"
        )
    }

    @Test("A key reads back one way only", arguments: [
        (["h|a", "b|c"], ["h|a|b", "c"]),
        (["h|a", "x", "y|z"], ["h|a", "x|y", "z"]),
        (["a\\", "b"], ["a", "\\b"]),
        (["a\\|b"], ["a|b"])
    ])
    func injective(_ pair: ([String], [String])) {
        #expect(key(pair.0) != key(pair.1))
    }

    /// The store's key takes its parts variadically, and Swift can't spread an array into that.
    private func key(_ parts: [String]) -> String {
        switch parts.count {
        case 1: TalkStore.identifier(parts[0])
        case 2: TalkStore.identifier(parts[0], parts[1])
        default: TalkStore.identifier(parts[0], parts[1], parts[2])
        }
    }

    @Test("Conversations whose raw keys collide are both kept")
    func conversationsDoNotOverwrite() async throws {
        let store = TalkStore(modelContainer: try .talkContainer(inMemory: true))
        await store.save(conversations: [Conversation(token: "b|c", displayName: "First")], accountID: "h|a")
        await store.save(conversations: [Conversation(token: "c", displayName: "Second")], accountID: "h|a|b")

        #expect(await store.conversations(accountID: "h|a").map(\.displayName) == ["First"])
        #expect(await store.conversations(accountID: "h|a|b").map(\.displayName) == ["Second"])
    }

    @Test("Messages whose raw keys collide are both kept")
    func messagesDoNotOverwrite() async throws {
        let store = TalkStore(modelContainer: try .talkContainer(inMemory: true))
        await store.save(messages: [message(1, token: "x", localID: "y|z")], accountID: "h|a")
        await store.save(messages: [message(2, token: "x|y", localID: "z")], accountID: "h|a")

        #expect(await store.messages(token: "x", accountID: "h|a").map(\.messageID) == [1])
        #expect(await store.messages(token: "x|y", accountID: "h|a").map(\.messageID) == [2])
    }

    @Test("A draft saved under the old key is still there, and saving it doesn't make a second")
    func legacyDraftSurvives() async throws {
        let container = try ModelContainer.talkContainer(inMemory: true)
        let legacy = ModelContext(container)
        legacy.insert(CachedDraft(identifier: "https://cloud.example.com|alice|tok", accountID: "https://cloud.example.com|alice", token: "tok", text: "half a thought"))
        try legacy.save()

        let store = TalkStore(modelContainer: container)
        let draft = try #require(await store.draft(token: "tok", accountID: "https://cloud.example.com|alice"))
        #expect(draft.text == "half a thought")

        await store.save(draft: Draft(token: "tok", text: "a whole thought"), accountID: "https://cloud.example.com|alice")
        #expect(await store.drafts(accountID: "https://cloud.example.com|alice").map(\.text) == ["a whole thought"])
    }

    @Test("Legacy conversations and messages are re-keyed rather than duplicated")
    func legacyRowsAreRekeyed() async throws {
        let container = try ModelContainer.talkContainer(inMemory: true)
        let account = "https://cloud.example.com|alice"
        let legacy = ModelContext(container)
        let conversation = Conversation(token: "tok", displayName: "Old name")
        legacy.insert(CachedConversation(
            identifier: "\(account)|tok", accountID: account, token: "tok",
            lastActivity: epoch, isFavorite: false, isArchived: false, unreadMessages: 0,
            displayName: "Old name", payload: try JSONEncoder().encode(conversation)
        ))
        let old = message(7, token: "tok", localID: "tok#7")
        legacy.insert(CachedMessage(
            identifier: "\(account)|tok|tok#7", accountID: account, token: "tok",
            messageID: 7, timestamp: epoch, payload: try JSONEncoder().encode(old)
        ))
        try legacy.save()

        let store = TalkStore(modelContainer: container)
        await store.save(conversations: [Conversation(token: "tok", displayName: "New name")], accountID: account)
        await store.save(messages: [message(7, token: "tok", localID: "tok#7")], accountID: account)

        #expect(await store.conversations(accountID: account).map(\.displayName) == ["New name"])
        #expect(await store.messages(token: "tok", accountID: account).map(\.messageID) == [7])
    }
}
