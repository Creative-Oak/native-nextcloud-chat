import Foundation

#if canImport(SwiftData) && canImport(CryptoKit)
import CryptoKit
import SwiftData

/// Turns a cache written before encryption into an encrypted one, once.
///
/// Encrypting the rows where they stand would not do it: SQLite keeps what it overwrites
/// and deletes in the file's free pages and its write-ahead log, so every message ever
/// cached would stay on disk in the clear. The file is rebuilt instead. What can't be
/// fetched again — the accounts and the unsent drafts — is read out, the store's files are
/// deleted, and those rows go back into a new store, sealed. Conversations and messages are
/// left behind; the server has them, and the first sync brings them back.
///
/// The sync cursors come across with their incremental position reset. Kept as they were,
/// the next fetch would ask only for conversations changed since the last one, and the
/// sidebar would stay empty.
enum CachePlaintextMigration {
    static func open(configuration: ModelConfiguration, schema: Schema, keyring: any CacheKeyring) throws -> ModelContainer {
        // The first container has to be gone before its files are, so it lives only here.
        let carried: Carried? = try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return try carry(from: ModelContext(container), keyring: keyring)
        }
        guard let carried else {
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        let url = configuration.url
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                // Not fatal: the rows are still cleared below, just without the guarantee
                // that nothing is left in the file.
                Log.persistence.error("Couldn’t remove the unencrypted cache file: \(error.localizedDescription)")
            }
        }

        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        try context.delete(model: CachedMessage.self)
        try context.delete(model: CachedConversation.self)
        try context.delete(model: CachedDraft.self)
        try context.delete(model: CachedSyncState.self)
        try context.delete(model: CachedAccount.self)
        for row in carried.accounts { context.insert(row) }
        for row in carried.drafts { context.insert(row) }
        for row in carried.syncStates { context.insert(row) }
        try context.save()
        Log.persistence.notice("Rebuilt the local cache encrypted")
        return container
    }

    /// The rows worth keeping, already sealed. Nil when there is nothing to migrate — and
    /// also when a key can't be had, in which case the old store is left exactly as it was
    /// for the next launch to try again, rather than wiped with drafts nobody could seal.
    private struct Carried {
        var accounts: [CachedAccount] = []
        var drafts: [CachedDraft] = []
        var syncStates: [CachedSyncState] = []
    }

    private static func carry(from context: ModelContext, keyring: any CacheKeyring) throws -> Carried? {
        let accounts = try context.fetch(FetchDescriptor<CachedAccount>())
        let drafts = try context.fetch(FetchDescriptor<CachedDraft>())
        var conversation = FetchDescriptor<CachedConversation>()
        conversation.fetchLimit = 1
        var message = FetchDescriptor<CachedMessage>()
        message.fetchLimit = 1

        // Everything written since encryption is sealed, so one clear row of any kind means
        // the store predates it.
        let firstConversation = try context.fetch(conversation)
        let firstMessage = try context.fetch(message)
        let isPlaintext = accounts.contains { !CacheCipher.isSealed($0.payload) }
            || drafts.contains { !CacheCipher.isSealed(text: $0.text) }
            || firstConversation.contains { !CacheCipher.isSealed($0.payload) }
            || firstMessage.contains { !CacheCipher.isSealed($0.payload) }
        guard isPlaintext else { return nil }

        do {
            var carried = Carried()
            for row in accounts {
                let key = try keyring.key(for: row.identifier)
                let payload = CacheCipher.isSealed(row.payload)
                    ? row.payload
                    : try CacheCipher.seal(row.payload, kind: .account, key: key)
                carried.accounts.append(CachedAccount(identifier: row.identifier, addedAt: row.addedAt, payload: payload))
            }
            for row in drafts where !row.text.isEmpty {
                let key = try keyring.key(for: row.accountID)
                let text = CacheCipher.isSealed(text: row.text) ? row.text : try CacheCipher.seal(text: row.text, key: key)
                carried.drafts.append(CachedDraft(
                    identifier: TalkStore.identifier(row.accountID, row.token),
                    accountID: row.accountID,
                    token: row.token,
                    text: text,
                    replyToMessageID: row.replyToMessageID,
                    editingMessageID: row.editingMessageID,
                    updatedAt: row.updatedAt
                ))
            }
            for row in try context.fetch(FetchDescriptor<CachedSyncState>()) {
                carried.syncStates.append(CachedSyncState(
                    accountID: row.accountID,
                    conversationsModifiedSince: 0,
                    lastFullRefresh: nil,
                    selectedToken: row.selectedToken,
                    talkHash: row.talkHash
                ))
            }
            return carried
        } catch {
            Log.persistence.error("Couldn’t encrypt the local cache yet, will try at next launch: \(String(describing: error))")
            return nil
        }
    }
}
#endif
