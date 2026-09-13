import Foundation

#if canImport(SwiftData)
import SwiftData

/// The local cache, as an actor.
///
/// Every method here runs off the main actor. Callers hand over and receive **domain
/// value types** — no `PersistentModel` ever escapes this file, so a SwiftData object can
/// never be touched from the wrong actor.
@ModelActor
actor TalkStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Accounts

    func accounts() -> [Account] {
        let descriptor = FetchDescriptor<CachedAccount>(sortBy: [SortDescriptor(\.addedAt)])
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.compactMap { try? Self.decoder.decode(Account.self, from: $0.payload) }
    }

    func save(account: Account) {
        guard let payload = try? Self.encoder.encode(account) else { return }
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

    /// Removes the account and everything cached for it. Credentials live in the Keychain
    /// and are deleted separately by ``AuthenticationService/signOut(account:)``.
    func deleteAccount(id accountID: String) {
        try? modelContext.delete(model: CachedMessage.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedConversation.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedDraft.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedSyncState.self, where: #Predicate { $0.accountID == accountID })
        try? modelContext.delete(model: CachedAccount.self, where: #Predicate { $0.identifier == accountID })
        persist()
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
        return rows.compactMap { try? Self.decoder.decode(Conversation.self, from: $0.payload) }
    }

    func save(conversations: [Conversation], accountID: String) {
        for conversation in conversations {
            guard let payload = try? Self.encoder.encode(conversation) else { continue }
            let identifier = Self.identifier(accountID, conversation.token)
            if let existing = fetchOne(FetchDescriptor<CachedConversation>(
                predicate: #Predicate { $0.identifier == identifier }
            )) {
                existing.lastActivity = conversation.lastActivity
                existing.isFavorite = conversation.isFavorite
                existing.isArchived = conversation.isArchived
                existing.unreadMessages = conversation.unreadMessages
                existing.displayName = conversation.displayName
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
                    displayName: conversation.displayName,
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
            .compactMap { try? Self.decoder.decode(Message.self, from: $0.payload) }
            .sorted { MessageTimeline.isOrderedBefore($0, $1) }
    }

    func save(messages: [Message], accountID: String) {
        for message in messages {
            guard let payload = try? Self.encoder.encode(message) else { continue }
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
        return Draft(
            token: row.token,
            text: row.text,
            replyToMessageID: row.replyToMessageID == 0 ? nil : row.replyToMessageID,
            editingMessageID: row.editingMessageID == 0 ? nil : row.editingMessageID,
            updatedAt: row.updatedAt
        )
    }

    func drafts(accountID: String) -> [Draft] {
        let descriptor = FetchDescriptor<CachedDraft>(predicate: #Predicate { $0.accountID == accountID })
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map {
            Draft(
                token: $0.token,
                text: $0.text,
                replyToMessageID: $0.replyToMessageID == 0 ? nil : $0.replyToMessageID,
                editingMessageID: $0.editingMessageID == 0 ? nil : $0.editingMessageID,
                updatedAt: $0.updatedAt
            )
        }
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

        if let existing {
            existing.text = draft.text
            existing.replyToMessageID = draft.replyToMessageID ?? 0
            existing.editingMessageID = draft.editingMessageID ?? 0
            existing.updatedAt = draft.updatedAt
        } else {
            modelContext.insert(CachedDraft(
                identifier: identifier,
                accountID: accountID,
                token: draft.token,
                text: draft.text,
                replyToMessageID: draft.replyToMessageID ?? 0,
                editingMessageID: draft.editingMessageID ?? 0,
                updatedAt: draft.updatedAt
            ))
        }
        persist()
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

    private static func identifier(_ parts: String...) -> String {
        parts.joined(separator: "|")
    }
}

extension ModelContainer {
    /// The app's on-disk store.
    static func talkContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "TalkForMac",
            schema: Schema(CacheSchema.models),
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: Schema(CacheSchema.models), configurations: [configuration])
    }
}
#endif
