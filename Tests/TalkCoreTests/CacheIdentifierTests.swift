import Foundation
import SwiftData
import Testing
@testable import TalkCore

/// The cache's row keys: that different rows never share one. Rows under the old keys are
/// re-keyed by the rebuild — see `CacheEncryptionTests`.
@Suite("Cache row keys")
struct CacheIdentifierTests {
    private let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeStore() throws -> TalkStore {
        let keyring = InMemoryCacheKeyring()
        return TalkStore(modelContainer: try .talkContainer(inMemory: true, keyring: keyring), keyring: keyring)
    }

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
        let store = try makeStore()
        await store.save(conversations: [Conversation(token: "b|c", displayName: "First")], accountID: "h|a")
        await store.save(conversations: [Conversation(token: "c", displayName: "Second")], accountID: "h|a|b")

        #expect(await store.conversations(accountID: "h|a").map(\.displayName) == ["First"])
        #expect(await store.conversations(accountID: "h|a|b").map(\.displayName) == ["Second"])
    }

    @Test("Messages whose raw keys collide are both kept")
    func messagesDoNotOverwrite() async throws {
        let store = try makeStore()
        await store.save(messages: [message(1, token: "x", localID: "y|z")], accountID: "h|a")
        await store.save(messages: [message(2, token: "x|y", localID: "z")], accountID: "h|a")

        #expect(await store.messages(token: "x", accountID: "h|a").map(\.messageID) == [1])
        #expect(await store.messages(token: "x|y", accountID: "h|a").map(\.messageID) == [2])
    }
}
