import Foundation

/// Talk's `messageType`.
enum MessageKind: String, Sendable, Codable {
    case comment
    case commentDeleted = "comment_deleted"
    case system
    case command
    case voiceMessage = "voice-message"
    case recordAudio = "record-audio"
    case recordVideo = "record-video"
    case unknown

    init(rawValue: String) {
        switch rawValue {
        case "comment": self = .comment
        case "comment_deleted": self = .commentDeleted
        case "system": self = .system
        case "command": self = .command
        case "voice-message": self = .voiceMessage
        case "record-audio": self = .recordAudio
        case "record-video": self = .recordVideo
        default: self = .unknown
        }
    }
}

/// A message's place in the send lifecycle. Server messages are always `.sent`; the other
/// states belong to locally-created messages that have not been acknowledged yet.
enum MessageDeliveryState: Sendable, Hashable, Codable {
    case sent
    /// In the outbox, waiting for the network.
    case queued
    /// A request is in flight.
    case sending
    /// Permanently failed; the user is offered a retry.
    case failed(reason: String)

    var isPending: Bool { self != .sent }
}

/// A chat message, in app terms.
///
/// `id` is the server id for everything that came from the server. Optimistic messages
/// carry `id == 0` until acknowledged and are identified by `localID` instead, which is
/// what `Identifiable` returns — so a pending row keeps its SwiftUI identity across
/// reconciliation and never flickers.
struct Message: Sendable, Hashable, Identifiable, Codable {
    var id: String { localID }

    /// Server message id. `0` for an optimistic message not yet acknowledged.
    var messageID: Int
    /// Stable identity for the lifetime of the row: the reference id for local messages,
    /// `token#id` for server messages.
    var localID: String
    var token: String
    var actor: MessageActor
    var timestamp: Date
    var kind: MessageKind
    /// The system event name (`call_started`, `user_added`, …); empty for normal messages.
    var systemMessage: String
    /// Raw text, still containing `{placeholder}` tokens.
    var text: String
    var parameters: [String: RichObject]
    var isReplyable: Bool
    var referenceID: String?
    var parent: ParentMessage?
    /// emoji → count
    var reactions: [String: Int]
    /// emoji I personally used
    var myReactions: Set<String>
    var isMarkdown: Bool
    var expirationTimestamp: Date?
    var lastEdit: EditInfo?
    var isSilent: Bool
    var isDeleted: Bool
    var deliveryState: MessageDeliveryState
    /// The thread this message is in — its first message, or a reply in it. Nil outside
    /// threads, and in caches from before threads (cap `threads`).
    var thread: MessageThread?

    /// The first message of a thread, which carries its title.
    var isThreadRoot: Bool { thread.map { $0.id == messageID } ?? false }

    var isSystem: Bool { kind == .system || !systemMessage.isEmpty }

    /// System events that exist only to tell clients to update their cache. Talk's own
    /// clients hide these, and so do we.
    static let invisibleSystemMessages: Set<String> = [
        "message_deleted", "message_edited", "reaction", "reaction_revoked",
        "reaction_deleted", "poll_voted", "message_expired"
    ]

    var isVisible: Bool {
        !(isSystem && Self.invisibleSystemMessages.contains(systemMessage))
    }

    var isDeletable: Bool {
        !isSystem && !isDeleted && kind != .commentDeleted
    }

    /// Whether this message can be answered in a one-to-one with its author, as Talk allows
    /// it: from a conversation that isn't already that one-to-one, to a person's message
    /// that isn't your own, as a user yourself. The server checks all of it again.
    func canBeRepliedToPrivately(in conversation: Conversation, myUserID: String) -> Bool {
        guard isReplyable, !isSystem, !isDeleted, kind != .commentDeleted, messageID > 0 else { return false }
        guard !conversation.isOneToOne, !conversation.isNoteToSelf else { return false }
        return actor.kind == .users && actor.id != myUserID
    }

    var isEditable: Bool {
        kind == .comment && !isDeleted && !isSystem
    }

    var isVoiceMessage: Bool { kind == .voiceMessage }

    /// True when the message is a file share (its text is a single `{file}` placeholder).
    var isFileShare: Bool {
        parameters.values.contains { $0.type == .file }
    }

    static func localID(token: String, messageID: Int) -> String { "\(token)#\(messageID)" }

    init(
        messageID: Int,
        localID: String? = nil,
        token: String,
        actor: MessageActor,
        timestamp: Date,
        kind: MessageKind = .comment,
        systemMessage: String = "",
        text: String,
        parameters: [String: RichObject] = [:],
        isReplyable: Bool = false,
        referenceID: String? = nil,
        parent: ParentMessage? = nil,
        reactions: [String: Int] = [:],
        myReactions: Set<String> = [],
        isMarkdown: Bool = false,
        expirationTimestamp: Date? = nil,
        lastEdit: EditInfo? = nil,
        isSilent: Bool = false,
        isDeleted: Bool = false,
        deliveryState: MessageDeliveryState = .sent,
        thread: MessageThread? = nil
    ) {
        self.messageID = messageID
        self.localID = localID ?? Self.localID(token: token, messageID: messageID)
        self.token = token
        self.actor = actor
        self.timestamp = timestamp
        self.kind = kind
        self.systemMessage = systemMessage
        self.text = text
        self.parameters = parameters
        self.isReplyable = isReplyable
        self.referenceID = referenceID
        self.parent = parent
        self.reactions = reactions
        self.myReactions = myReactions
        self.isMarkdown = isMarkdown
        self.expirationTimestamp = expirationTimestamp
        self.lastEdit = lastEdit
        self.isSilent = isSilent
        self.isDeleted = isDeleted
        self.deliveryState = deliveryState
        self.thread = thread
    }

    struct EditInfo: Sendable, Hashable, Codable {
        var actor: MessageActor
        var timestamp: Date
    }
}

/// The parent of a reply. Talk sends the whole parent message inline; we keep only what a
/// quote bubble needs, so a deep reply chain can't blow up the cache.
struct ParentMessage: Sendable, Hashable, Codable {
    var messageID: Int
    var actor: MessageActor
    var text: String
    var parameters: [String: RichObject]
    var isDeleted: Bool
    var timestamp: Date
    /// The conversation the parent is in, when that is not the reply's own — a private
    /// reply. Nil otherwise, and for anything cached before it was kept.
    var token: String?

    init(messageID: Int, actor: MessageActor, text: String, parameters: [String: RichObject] = [:], isDeleted: Bool = false, timestamp: Date = .distantPast, token: String? = nil) {
        self.messageID = messageID
        self.actor = actor
        self.text = text
        self.parameters = parameters
        self.isDeleted = isDeleted
        self.timestamp = timestamp
        self.token = token
    }
}

/// A thread a message belongs to. Talk threads hang off one message — the first — and take
/// its id; every reply under it, however deep, is in it.
struct MessageThread: Sendable, Hashable, Codable {
    var id: Int
    var title: String
    /// How many replies it had when the server sent this message: the newest message in a
    /// thread knows the count best.
    var replies: Int

    /// Each thread's reply count, by thread id: the newest of its messages knows it best.
    static func replyCounts(in messages: some Sequence<Message>) -> [Int: Int] {
        var newest: [Int: (id: Int, replies: Int)] = [:]
        for message in messages where message.messageID > 0 {
            guard let thread = message.thread else { continue }
            if let known = newest[thread.id], known.id >= message.messageID { continue }
            newest[thread.id] = (message.messageID, thread.replies)
        }
        return newest.mapValues(\.replies)
    }
}
