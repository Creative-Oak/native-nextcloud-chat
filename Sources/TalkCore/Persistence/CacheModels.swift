import Foundation

#if canImport(SwiftData)
import SwiftData

/// The local cache schema.
///
/// Design note: the server is authoritative and this is a cache, so each row stores a few
/// **indexed columns** for querying plus the domain model as an encoded `payload`. That
/// keeps the schema tiny (fewer migrations, fewer SwiftData surprises) while still
/// supporting the only queries the app makes: "conversations for this account, by
/// activity" and "messages in this conversation, by id".
@Model
final class CachedAccount {
    // `.unique` implies an index; adding an explicit one as well is redundant.
    @Attribute(.unique) var identifier: String
    var addedAt: Date
    var payload: Data

    init(identifier: String, addedAt: Date, payload: Data) {
        self.identifier = identifier
        self.addedAt = addedAt
        self.payload = payload
    }
}

@Model
final class CachedConversation {
    /// Account id and token, escaped and joined by `TalkStore.identifier(_:)` — unique per
    /// account, so two accounts can share a token.
    @Attribute(.unique) var identifier: String
    var accountID: String
    var token: String
    var lastActivity: Date
    var isFavorite: Bool
    var isArchived: Bool
    var unreadMessages: Int
    var displayName: String
    var payload: Data

    init(
        identifier: String,
        accountID: String,
        token: String,
        lastActivity: Date,
        isFavorite: Bool,
        isArchived: Bool,
        unreadMessages: Int,
        displayName: String,
        payload: Data
    ) {
        self.identifier = identifier
        self.accountID = accountID
        self.token = token
        self.lastActivity = lastActivity
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.unreadMessages = unreadMessages
        self.displayName = displayName
        self.payload = payload
    }
}

@Model
final class CachedMessage {
    /// Account id, token and local id, escaped and joined by `TalkStore.identifier(_:)`.
    @Attribute(.unique) var identifier: String
    var accountID: String
    var token: String
    /// `0` for a message that hasn't been acknowledged by the server yet.
    var messageID: Int
    var timestamp: Date
    var payload: Data

    init(
        identifier: String,
        accountID: String,
        token: String,
        messageID: Int,
        timestamp: Date,
        payload: Data
    ) {
        self.identifier = identifier
        self.accountID = accountID
        self.token = token
        self.messageID = messageID
        self.timestamp = timestamp
        self.payload = payload
    }
}

/// A composed-but-unsent message. Survives quit, relaunch, and switching conversations.
@Model
final class CachedDraft {
    @Attribute(.unique) var identifier: String
    var accountID: String
    var token: String
    var text: String
    /// The message being replied to, if the draft was composed as a reply.
    var replyToMessageID: Int
    /// The message being edited, if the draft is an edit in progress.
    var editingMessageID: Int
    var updatedAt: Date

    init(
        identifier: String,
        accountID: String,
        token: String,
        text: String,
        replyToMessageID: Int = 0,
        editingMessageID: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.identifier = identifier
        self.accountID = accountID
        self.token = token
        self.text = text
        self.replyToMessageID = replyToMessageID
        self.editingMessageID = editingMessageID
        self.updatedAt = updatedAt
    }
}

/// Cursors and bookkeeping, one row per account.
@Model
final class CachedSyncState {
    @Attribute(.unique) var accountID: String
    /// Feed back as `modifiedSince` on the next incremental conversation fetch.
    var conversationsModifiedSince: Int
    var lastFullRefresh: Date?
    /// The conversation that was selected when the app last quit.
    var selectedToken: String?
    var talkHash: String?

    init(
        accountID: String,
        conversationsModifiedSince: Int = 0,
        lastFullRefresh: Date? = nil,
        selectedToken: String? = nil,
        talkHash: String? = nil
    ) {
        self.accountID = accountID
        self.conversationsModifiedSince = conversationsModifiedSince
        self.lastFullRefresh = lastFullRefresh
        self.selectedToken = selectedToken
        self.talkHash = talkHash
    }
}

enum CacheSchema {
    static let models: [any PersistentModel.Type] = [
        CachedAccount.self,
        CachedConversation.self,
        CachedMessage.self,
        CachedDraft.self,
        CachedSyncState.self
    ]
}
#endif
