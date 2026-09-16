import Foundation

#if canImport(SwiftData) && canImport(CryptoKit)
import CryptoKit
import SwiftData

/// The local cache, as an actor.
///
/// Every method here runs off the main actor. Callers hand over and receive **domain
/// value types** — no `PersistentModel` ever escapes this file, so a SwiftData object can
/// never be touched from the wrong actor.
///
/// **What is written is sealed.** Message bodies, conversations, drafts and account details
/// are encrypted with the account's key from a ``CacheKeyring`` before they reach SQLite —
/// see ``CacheCipher``. What stays readable is what the queries need: account ids, tokens,
/// message ids, timestamps and counts. Signing out destroys the key along with the rows, so
/// whatever SQLite leaves behind in the file, and whatever a backup kept, can't be read.
/// A key that can't be had means the cache is skipped, never written in the clear.
actor TalkStore: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private let keyring: any CacheKeyring
    /// Keys already fetched, so the keychain is asked once per account rather than per row.
    private var keys: [String: SymmetricKey] = [:]

    init(modelContainer: ModelContainer, keyring: any CacheKeyring) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.keyring = keyring
    }

    // MARK: - Accounts

    func accounts() -> [Account] {
        let descriptor = FetchDescriptor<CachedAccount>(sortBy: [SortDescriptor(\.addedAt)])
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.compactMap { open(Account.self, from: $0.payload, kind: .account, accountID: $0.identifier) }
    }

    func save(account: Account) {
        guard let payload = seal(account, kind: .account, accountID: account.id) else { return }
        let identifier = account.id
        let existing = fetchOne(FetchDescriptor<CachedAccount>(
            predicate: #Predicate { $0.identifier == identifier }
        ))
        if let existing {
            existing.payload = payload
        } else {
            modelContext.insert(CachedAccount(identifier: identifier, addedAt: account.addedAt, payload: payload))
        }
        persist()
    }

    /// Removes the account and everything cached for it, and destroys its cache key.
    /// Credentials live in the Keychain and are deleted separately by
    /// ``AuthenticationService/signOut(account:)``.
    func deleteAccount(id accountID: String) {
        try? modelContext.delete(model: CachedMessage.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedConversation.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedDraft.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedSyncState.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedAccount.self, where: #Predicate { $0.identifier == accountID })
        persist()

        // The rows are gone from the table, not necessarily from the file. The key is what
        // makes the remainder unreadable, so failing to destroy it is worth saying.
        keys[accountID] = nil
        do {
            try keyring.removeKey(for: accountID)
        } catch {
            Log.persistence.error("Couldn’t destroy a signed-out account’s cache key: \(error.localizedDescription)")
        }
    }

    // MARK: - Conversations

    /// Everything we know, newest first — this is what paints the sidebar at launch,
    /// before any network call has returned.
    func conversations(accountID: String) -> [Conversation] {
        var descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.lastActivity, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.compactMap { open(Conversation.self, from: $0.payload, kind: .conversation, accountID: accountID) }
    }

    func save(conversations: [Conversation], accountID: String) {
        for conversation in conversations {
            guard let payload = seal(conversation, kind: .conversation, accountID: accountID) else { continue }
            let identifier = Self.identifier(accountID, conversation.token)
            if let existing = fetchOne(FetchDescriptor<CachedConversation>(
                predicate: #Predicate { $0.identifier == identifier }
            )) {
                existing.lastActivity = conversation.lastActivity
                existing.isFavorite = conversation.isFavorite
                existing.isArchived = conversation.isArchived
                existing.unreadMessages = conversation.unreadMessages
                existing.displayName = ""
                existing.payload = payload
            } else {
                modelContext.insert(CachedConversation(
                    identifier: identifier,
                    accountID: accountID,
                    token: conversation.token,
                    lastActivity: conversation.lastActivity,
                    isFavorite: conversation.isFavorite,
                    isArchived: conversation.isArchived,
                    unreadMessages: conversation.unreadMessages,
                    // Nothing queries the name, and a readable column of every conversation
                    // name is most of what encrypting the payload is meant to hide.
                    displayName: "",
                    payload: payload
                ))
            }
        }
        persist()
    }

    /// Only ever called with the result of a **full** refresh — an incremental one can't
    /// prove a conversation is gone.
    func deleteConversations(tokens: [String], accountID: String) {
        for token in tokens {
            let identifier = Self.identifier(accountID, token)
            try? modelContext.delete(model: CachedConversation.self, where: #Predicate { $0.identifier == identifier })
            try? modelContext.delete(model: CachedMessage.self, where: #Predicate {
                $0.accountID == accountID && $0.token == token
            })
        }
        persist()
    }

    // MARK: - Messages

    /// The most recent `limit` messages, oldest first — the shape the timeline wants.
    func messages(token: String, accountID: String, limit: Int = 200) -> [Message] {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountID == accountID && $0.token == token },
            sortBy: [SortDescriptor(\.messageID, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows
            .compactMap { open(Message.self, from: $0.payload, kind: .message, accountID: accountID) }
            .sorted { MessageTimeline.isOrderedBefore($0, $1) }
    }

    func save(messages: [Message], accountID: String) {
        for message in messages {
            guard let payload = seal(message, kind: .message, accountID: accountID) else { continue }
            let identifier = Self.identifier(accountID, message.token, message.localID)
            if let existing = fetchOne(FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.identifier == identifier }
            )) {
                existing.messageID = message.messageID
                existing.timestamp = message.timestamp
                existing.payload = payload
            } else {
                modelContext.insert(CachedMessage(
                    identifier: identifier,
                    accountID: accountID,
                    token: message.token,
                    messageID: message.messageID,
                    timestamp: message.timestamp,
                    payload: payload
                ))
            }
        }
        persist()
    }

    func deleteMessage(localID: String, token: String, accountID: String) {
        let identifier = Self.identifier(accountID, token, localID)
        try? modelContext.delete(model: CachedMessage.self, where: #Predicate { $0.identifier == identifier })
        persist()
    }

    /// Keeps the cache from growing without bound: the newest `keeping` messages per
    /// conversation are plenty for instant opening, and older history is one fetch away.
    func trimMessages(token: String, accountID: String, keeping: Int = 500) {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountID == accountID && $0.token == token },
            sortBy: [SortDescriptor(\.messageID, order: .reverse)]
        )
        descriptor.fetchOffset = keeping
        guard let surplus = try? modelContext.fetch(descriptor), !surplus.isEmpty else { return }
        for row in surplus { modelContext.delete(row) }
        persist()
    }

    // MARK: - Drafts

    func draft(token: String, accountID: String) -> Draft? {
        let identifier = Self.identifier(accountID, token)
        guard let row = fetchOne(FetchDescriptor<CachedDraft>(
            predicate: #Predicate { $0.identifier == identifier }
        )) else { return nil }
        return draft(from: row)
    }

    func drafts(accountID: String) -> [Draft] {
        let descriptor = FetchDescriptor<CachedDraft>(predicate: #Predicate { $0.accountID == accountID })
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.compactMap(draft(from:))
    }

    func save(draft: Draft, accountID: String) {
        let identifier = Self.identifier(accountID, draft.token)
        let existing = fetchOne(FetchDescriptor<CachedDraft>(
            predicate: #Predicate { $0.identifier == identifier }
        ))

        guard !draft.isEmpty else {
            if let existing { modelContext.delete(existing) ; persist() }
            return
        }
        guard let key = key(for: accountID), let text = try? CacheCipher.seal(text: draft.text, key: key) else { return }

        if let existing {
            existing.text = text
            existing.replyToMessageID = draft.replyToMessageID ?? 0
            existing.editingMessageID = draft.editingMessageID ?? 0
            existing.updatedAt = draft.updatedAt
        } else {
            modelContext.insert(CachedDraft(
                identifier: identifier,
                accountID: accountID,
                token: draft.token,
                text: text,
                replyToMessageID: draft.replyToMessageID ?? 0,
                editingMessageID: draft.editingMessageID ?? 0,
                updatedAt: draft.updatedAt
            ))
        }
        persist()
    }

    private func draft(from row: CachedDraft) -> Draft? {
        guard let key = key(for: row.accountID), let text = try? CacheCipher.open(text: row.text, key: key) else {
            return nil
        }
        return Draft(
            token: row.token,
            text: text,
            replyToMessageID: row.replyToMessageID == 0 ? nil : row.replyToMessageID,
            editingMessageID: row.editingMessageID == 0 ? nil : row.editingMessageID,
            updatedAt: row.updatedAt
        )
    }

    // MARK: - Sync state

    func syncState(accountID: String) -> SyncCursor {
        guard let row = fetchOne(FetchDescriptor<CachedSyncState>(
            predicate: #Predicate { $0.accountID == accountID }
        )) else { return SyncCursor() }
        return SyncCursor(
            conversationsModifiedSince: row.conversationsModifiedSince == 0 ? nil : row.conversationsModifiedSince,
            lastFullRefresh: row.lastFullRefresh,
            selectedToken: row.selectedToken,
            talkHash: row.talkHash
        )
    }

    func save(syncState: SyncCursor, accountID: String) {
        let existing = fetchOne(FetchDescriptor<CachedSyncState>(
            predicate: #Predicate { $0.accountID == accountID }
        ))
        if let existing {
            existing.conversationsModifiedSince = syncState.conversationsModifiedSince ?? 0
            existing.lastFullRefresh = syncState.lastFullRefresh
            existing.selectedToken = syncState.selectedToken
            existing.talkHash = syncState.talkHash
        } else {
            modelContext.insert(CachedSyncState(
                accountID: accountID,
                conversationsModifiedSince: syncState.conversationsModifiedSince ?? 0,
                lastFullRefresh: syncState.lastFullRefresh,
                selectedToken: syncState.selectedToken,
                talkHash: syncState.talkHash
            ))
        }
        persist()
    }

    // MARK: - Sealing

    private func key(for accountID: String) -> SymmetricKey? {
        if let key = keys[accountID] { return key }
        do {
            let key = try keyring.key(for: accountID)
            keys[accountID] = key
            return key
        } catch {
            // Not cached is recoverable — the server has all of it. Cached in the clear is not.
            Log.persistence.error("No cache key, so nothing is cached for now: \(error.localizedDescription)")
            return nil
        }
    }

    private func seal<T: Encodable>(_ value: T, kind: CacheCipher.Kind, accountID: String) -> Data? {
        guard let key = key(for: accountID), let plaintext = try? Self.encoder.encode(value) else { return nil }
        return try? CacheCipher.seal(plaintext, kind: kind, key: key)
    }

    /// Nil for anything that won't open — including a row sealed under a key that has since
    /// been destroyed, which is a cache miss and nothing more.
    private func open<T: Decodable>(_ type: T.Type, from data: Data, kind: CacheCipher.Kind, accountID: String) -> T? {
        guard let key = key(for: accountID), let plaintext = try? CacheCipher.open(data, kind: kind, key: key) else {
            return nil
        }
        return try? Self.decoder.decode(type, from: plaintext)
    }

    // MARK: - Plumbing

    private func fetchOne<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func persist() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            // A cache write failing must never take the app down: the server is the source
            // of truth and the next sync will refill it.
            Log.persistence.error("Cache save failed: \(error.localizedDescription)")
        }
    }

    /// A row's unique key, made from the parts that identify it.
    ///
    /// Each part is escaped before they are joined — `\` as `\\`, `|` as `\|` — so a key
    /// reads back one way only. Joined raw, the account `h|alice` with the token `b|c` and
    /// the account `h|alice|b` with the token `c` made the same key, and because the column
    /// is unique, saving one quietly replaced the other. Talk's own tokens never contain a
    /// `|`, but the key should not depend on what a server chooses to send.
    ///
    /// Stores from before this are re-keyed when ``CachePlaintextMigration`` rebuilds them.
    static func identifier(_ parts: String...) -> String {
        parts
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|") }
            .joined(separator: "|")
    }
}

extension ModelContainer {
    /// The app's on-disk store, with any cache from before encryption turned into an
    /// encrypted one first — see ``CachePlaintextMigration``.
    ///
    /// - Parameter url: where the store lives. Nil is the default location; tests pass
    ///   their own.
    static func talkContainer(
        inMemory: Bool = false,
        url: URL? = nil,
        keyring: any CacheKeyring
    ) throws -> ModelContainer {
        let schema = Schema(CacheSchema.models)
        let configuration = if inMemory {
            ModelConfiguration("Kvidr", schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            ModelConfiguration("Kvidr", schema: schema, url: url)
        } else {
            ModelConfiguration("Kvidr", schema: schema)
        }
        guard !inMemory else { return try ModelContainer(for: schema, configurations: [configuration]) }
        return try CachePlaintextMigration.open(configuration: configuration, schema: schema, keyring: keyring)
    }
}
#endif
