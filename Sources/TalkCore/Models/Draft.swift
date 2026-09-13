import Foundation

/// A composed-but-unsent message for one conversation.
struct Draft: Sendable, Hashable, Codable {
    var token: String
    var text: String
    var replyToMessageID: Int?
    /// Set while the user is editing an existing message rather than composing a new one.
    var editingMessageID: Int?
    var updatedAt: Date

    init(
        token: String,
        text: String = "",
        replyToMessageID: Int? = nil,
        editingMessageID: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.token = token
        self.text = text
        self.replyToMessageID = replyToMessageID
        self.editingMessageID = editingMessageID
        self.updatedAt = updatedAt
    }

    /// An empty draft with no reply context is the same as no draft at all.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyToMessageID == nil && editingMessageID == nil
    }

    var isEditing: Bool { editingMessageID != nil }
}

/// Persisted sync cursors for one account.
struct SyncCursor: Sendable, Hashable, Codable {
    var conversationsModifiedSince: Int?
    var lastFullRefresh: Date?
    var selectedToken: String?
    var talkHash: String?
}
