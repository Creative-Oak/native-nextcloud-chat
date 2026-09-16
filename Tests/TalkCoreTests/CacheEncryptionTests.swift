import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import TalkCore

/// That the cache on disk says nothing without the account's key, and that a cache from
/// before encryption becomes one — keeping the drafts, leaving no plaintext in the files.
@Suite("Encrypted cache")
struct CacheEncryptionTests {
    private let account = "https://cloud.example.com|alice"
    private let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    private func scratchStoreURL() throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("Kvidr.store"))
    }

    /// Every byte of every file SQLite keeps for the store — the database, its write-ahead
    /// log and its shared memory — since plaintext left in any of them is still on disk.
    private func bytesOnDisk(in directory: URL) throws -> Data {
        var all = Data()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            all.append(try Data(contentsOf: file))
        }
        return all
    }

    private func message(_ text: String) -> Message {
        Message(
            messageID: 1,
            token: "tok",
            actor: MessageActor(kind: .users, id: "bob", displayName: "Bob"),
            timestamp: epoch,
            text: text
        )
    }

    @Test("What is cached reads back")
    func roundTrip() async throws {
        let keyring = InMemoryCacheKeyring()
        let store = TalkStore(modelContainer: try .talkContainer(inMemory: true, keyring: keyring), keyring: keyring)
        let server = try ServerAddress.parse("https://cloud.example.com")
        let alice = Account(server: server, loginName: "alice", userID: "alice", displayName: "Alice")

        await store.save(account: alice)
        await store.save(conversations: [Conversation(token: "tok", displayName: "Budget")], accountID: alice.id)
        await store.save(messages: [message("the numbers are in")], accountID: alice.id)
        await store.save(draft: Draft(token: "tok", text: "half a thought"), accountID: alice.id)

        #expect(await store.accounts().map(\.displayName) == ["Alice"])
        #expect(await store.conversations(accountID: alice.id).map(\.displayName) == ["Budget"])
        #expect(await store.messages(token: "tok", accountID: alice.id).map(\.text) == ["the numbers are in"])
        #expect(await store.draft(token: "tok", accountID: alice.id)?.text == "half a thought")
    }

    @Test("Nothing readable reaches the files")
    func nothingInTheClear() async throws {
        let (directory, url) = try scratchStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyring = InMemoryCacheKeyring()

        do {
            let store = TalkStore(modelContainer: try .talkContainer(url: url, keyring: keyring), keyring: keyring)
            await store.save(conversations: [Conversation(token: "tok", displayName: "Quarterly Secrets")], accountID: account)
            await store.save(messages: [message("the vault code is 4711")], accountID: account)
            await store.save(draft: Draft(token: "tok", text: "do not tell Bob"), accountID: account)
        }

        let disk = try bytesOnDisk(in: directory)
        for secret in ["Quarterly Secrets", "the vault code is 4711", "do not tell Bob"] {
            #expect(disk.range(of: Data(secret.utf8)) == nil, "\(secret) is on disk in the clear")
        }
    }

    @Test("Signing out destroys the key, and what's left can't be read")
    func signOutShredsKey() async throws {
        let keyring = InMemoryCacheKeyring()
        let container = try ModelContainer.talkContainer(inMemory: true, keyring: keyring)
        let store = TalkStore(modelContainer: container, keyring: keyring)
        await store.save(messages: [message("hello")], accountID: account)
        #expect(keyring.hasKey(for: account))

        await store.deleteAccount(id: account)
        #expect(!keyring.hasKey(for: account))
    }

    @Test("A row under a key that's gone is a miss, not a crash")
    func lostKeyIsAMiss() async throws {
        let container = try ModelContainer.talkContainer(inMemory: true, keyring: InMemoryCacheKeyring())
        await TalkStore(modelContainer: container, keyring: InMemoryCacheKeyring())
            .save(messages: [message("hello")], accountID: account)

        // A fresh keyring: same rows, different key.
        let store = TalkStore(modelContainer: container, keyring: InMemoryCacheKeyring())
        #expect(await store.messages(token: "tok", accountID: account).isEmpty)
    }

    @Test("A cache from before encryption is rebuilt: drafts kept, sealed, re-keyed, nothing left in the clear")
    func plaintextStoreIsRebuilt() async throws {
        let (directory, url) = try scratchStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try ServerAddress.parse("https://cloud.example.com")
        let alice = Account(server: server, loginName: "alice", userID: "alice", displayName: "Alice Liddell")

        // Written the way the app did before: plaintext payloads, raw-joined keys.
        do {
            let schema = Schema(CacheSchema.models)
            let legacy = try ModelContainer(for: schema, configurations: [ModelConfiguration("Kvidr", schema: schema, url: url)])
            let context = ModelContext(legacy)
            context.insert(CachedAccount(identifier: alice.id, addedAt: epoch, payload: try JSONEncoder().encode(alice)))
            context.insert(CachedDraft(identifier: "\(alice.id)|tok", accountID: alice.id, token: "tok", text: "meet me at the old mill"))
            context.insert(CachedConversation(
                identifier: "\(alice.id)|tok", accountID: alice.id, token: "tok", lastActivity: epoch,
                isFavorite: false, isArchived: false, unreadMessages: 0, displayName: "Secret Society",
                payload: try JSONEncoder().encode(Conversation(token: "tok", displayName: "Secret Society"))
            ))
            context.insert(CachedMessage(
                identifier: "\(alice.id)|tok|tok#1", accountID: alice.id, token: "tok", messageID: 1,
                timestamp: epoch, payload: try JSONEncoder().encode(message("the password is swordfish"))
            ))
            context.insert(CachedSyncState(accountID: alice.id, conversationsModifiedSince: 1_749_999_000, selectedToken: "tok"))
            try context.save()
        }
        #expect(try bytesOnDisk(in: directory).range(of: Data("swordfish".utf8)) != nil, "the setup really is plaintext")

        let keyring = InMemoryCacheKeyring()
        let store = TalkStore(modelContainer: try .talkContainer(url: url, keyring: keyring), keyring: keyring)

        #expect(await store.accounts().map(\.displayName) == ["Alice Liddell"])
        #expect(await store.draft(token: "tok", accountID: alice.id)?.text == "meet me at the old mill")
        // Refetched rather than carried.
        #expect(await store.conversations(accountID: alice.id).isEmpty)
        #expect(await store.messages(token: "tok", accountID: alice.id).isEmpty)
        // Kept where it was, but asking for everything again, since the conversations are gone.
        let cursor = await store.syncState(accountID: alice.id)
        #expect(cursor.selectedToken == "tok")
        #expect(cursor.conversationsModifiedSince == nil)
        // Saving the draft updates the carried row rather than adding one under another key.
        await store.save(draft: Draft(token: "tok", text: "the new mill"), accountID: alice.id)
        #expect(await store.drafts(accountID: alice.id).map(\.text) == ["the new mill"])

        let disk = try bytesOnDisk(in: directory)
        for secret in ["swordfish", "Secret Society", "old mill", "Alice Liddell"] {
            #expect(disk.range(of: Data(secret.utf8)) == nil, "\(secret) survived the rebuild in the clear")
        }
    }

    @Test("An encrypted store is opened as it is")
    func encryptedStoreIsLeftAlone() async throws {
        let (directory, url) = try scratchStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyring = InMemoryCacheKeyring()

        do {
            let store = TalkStore(modelContainer: try .talkContainer(url: url, keyring: keyring), keyring: keyring)
            await store.save(messages: [message("still here")], accountID: account)
            await store.save(conversations: [Conversation(token: "tok", displayName: "Room")], accountID: account)
        }

        let reopened = TalkStore(modelContainer: try .talkContainer(url: url, keyring: keyring), keyring: keyring)
        #expect(await reopened.messages(token: "tok", accountID: account).map(\.text) == ["still here"])
        #expect(await reopened.conversations(accountID: account).map(\.displayName) == ["Room"])
    }
}

/// A keychain that won't answer — the state a Mac app is in without its access-group
/// entitlement, and the one that sent everyone back to the sign-in screen.
private struct BrokenKeyring: CacheKeyring {
    func key(for accountID: String) throws -> SymmetricKey { throw KeychainError.unexpectedStatus(-34018) }
    func removeKey(for accountID: String) throws { throw KeychainError.unexpectedStatus(-34018) }
}

@Suite("Encrypted cache, keychain unavailable")
struct CacheWithoutKeychainTests {
    @Test("An unconverted store still reads, and nothing is written to it in the clear")
    func unconvertedStoreStillReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kvidr.store")
        let server = try ServerAddress.parse("https://cloud.example.com")
        let alice = Account(server: server, loginName: "alice", userID: "alice", displayName: "Alice")

        do {
            let schema = Schema(CacheSchema.models)
            let legacy = try ModelContainer(for: schema, configurations: [ModelConfiguration("Kvidr", schema: schema, url: url)])
            let context = ModelContext(legacy)
            context.insert(CachedAccount(identifier: alice.id, addedAt: .now, payload: try JSONEncoder().encode(alice)))
            context.insert(CachedDraft(identifier: TalkStore.identifier(alice.id, "tok"), accountID: alice.id, token: "tok", text: "still mine"))
            try context.save()
        }

        let keyring = BrokenKeyring()
        let store = TalkStore(modelContainer: try .talkContainer(url: url, keyring: keyring), keyring: keyring)

        // Still signed in, draft still there.
        #expect(await store.accounts().map(\.id) == [alice.id])
        #expect(await store.draft(token: "tok", accountID: alice.id)?.text == "still mine")

        // And a new draft is not cached rather than cached readable.
        await store.save(draft: Draft(token: "other", text: "never in the clear"), accountID: alice.id)
        #expect(await store.draft(token: "other", accountID: alice.id) == nil)
    }
}
