import Foundation

/// A chat message exactly as Talk sends it. See docs/NEXTCLOUD_API.md § 5.6.
///
/// Every capability-dependent field is optional, because an older server simply omits it.
struct MessageDTO: Decodable, Sendable {
    let id: Int
    let token: String?
    let actorType: String
    let actorId: String
    let actorDisplayName: String?
    let timestamp: Int
    let systemMessage: String?
    let messageType: String?
    let message: String
    let messageParameters: [String: RichObjectDTO]
    let isReplyable: Bool?
    let referenceId: String?
    let expirationTimestamp: Int?
    let parent: ParentMessageDTO?
    let reactions: [String: Int]
    let reactionsSelf: [String]?
    let markdown: Bool?
    let silent: Bool?
    let deleted: Bool?
    let lastEditActorType: String?
    let lastEditActorId: String?
    let lastEditActorDisplayName: String?
    let lastEditTimestamp: Int?
    let threadId: Int?
    let isThread: Bool?
    let threadTitle: String?
    let threadReplies: Int?

    private enum CodingKeys: String, CodingKey {
        case id, token, actorType, actorId, actorDisplayName, timestamp, systemMessage
        case messageType, message, messageParameters, isReplyable, referenceId
        case expirationTimestamp, parent, reactions, reactionsSelf, markdown, silent, deleted
        case lastEditActorType, lastEditActorId, lastEditActorDisplayName, lastEditTimestamp
        case threadId, isThread, threadTitle, threadReplies
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Lenient.int(container, .id) ?? 0
        token = try? container.decodeIfPresent(String.self, forKey: .token)
        actorType = (try? container.decodeIfPresent(String.self, forKey: .actorType)) ?? ""
        actorId = Lenient.string(container, .actorId) ?? ""
        actorDisplayName = try? container.decodeIfPresent(String.self, forKey: .actorDisplayName)
        timestamp = Lenient.int(container, .timestamp) ?? 0
        systemMessage = try? container.decodeIfPresent(String.self, forKey: .systemMessage)
        messageType = try? container.decodeIfPresent(String.self, forKey: .messageType)
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        isReplyable = Lenient.bool(container, .isReplyable)
        referenceId = try? container.decodeIfPresent(String.self, forKey: .referenceId)
        expirationTimestamp = Lenient.int(container, .expirationTimestamp)
        parent = try? container.decodeIfPresent(ParentMessageDTO.self, forKey: .parent)
        reactionsSelf = try? container.decodeIfPresent([String].self, forKey: .reactionsSelf)
        markdown = Lenient.bool(container, .markdown)
        silent = Lenient.bool(container, .silent)
        deleted = Lenient.bool(container, .deleted)
        lastEditActorType = try? container.decodeIfPresent(String.self, forKey: .lastEditActorType)
        lastEditActorId = try? container.decodeIfPresent(String.self, forKey: .lastEditActorId)
        lastEditActorDisplayName = try? container.decodeIfPresent(String.self, forKey: .lastEditActorDisplayName)
        lastEditTimestamp = Lenient.int(container, .lastEditTimestamp)
        threadId = Lenient.int(container, .threadId)
        isThread = Lenient.bool(container, .isThread)
        threadTitle = try? container.decodeIfPresent(String.self, forKey: .threadTitle)
        threadReplies = Lenient.int(container, .threadReplies)

        // Both of these are `[]` rather than `{}` when empty — PHP's array serialization.
        messageParameters = (try? container.decodeIfPresent([String: RichObjectDTO].self, forKey: .messageParameters)) ?? [:]
        reactions = (try? container.decodeIfPresent([String: Int].self, forKey: .reactions)) ?? [:]
    }

    func model(token fallbackToken: String) -> Message {
        let resolvedToken = token ?? fallbackToken
        let kind = MessageKind(rawValue: messageType ?? "comment")
        let system = systemMessage ?? ""

        var edit: Message.EditInfo?
        if let editTimestamp = lastEditTimestamp, editTimestamp > 0 {
            edit = Message.EditInfo(
                actor: MessageActor(
                    type: lastEditActorType ?? "users",
                    id: lastEditActorId ?? "",
                    displayName: lastEditActorDisplayName
                ),
                timestamp: Date(timeIntervalSince1970: TimeInterval(editTimestamp))
            )
        }

        let expiration = (expirationTimestamp ?? 0) > 0
            ? Date(timeIntervalSince1970: TimeInterval(expirationTimestamp ?? 0))
            : nil

        return Message(
            messageID: id,
            token: resolvedToken,
            actor: MessageActor(type: actorType, id: actorId, displayName: actorDisplayName),
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            kind: kind,
            systemMessage: system,
            text: message,
            parameters: messageParameters.objects,
            isReplyable: isReplyable ?? false,
            referenceID: referenceId?.isEmpty == false ? referenceId : nil,
            parent: parent?.model(),
            reactions: reactions.filter { $0.value > 0 },
            myReactions: Set(reactionsSelf ?? []),
            isMarkdown: markdown ?? false,
            expirationTimestamp: expiration,
            lastEdit: edit,
            isSilent: silent ?? false,
            isDeleted: deleted ?? (kind == .commentDeleted),
            // Every message has a `threadId` — its own id when it starts nothing — but only
            // one in an actual thread says `isThread`.
            thread: isThread == true ? threadId.map { MessageThread(id: $0, title: threadTitle ?? "", replies: threadReplies ?? 0) } : nil
        )
    }
}

struct ParentMessageDTO: Decodable, Sendable {
    let id: Int
    let actorType: String?
    let actorId: String?
    let actorDisplayName: String?
    let message: String?
    let messageParameters: [String: RichObjectDTO]
    let messageType: String?
    let deleted: Bool?
    let timestamp: Int?

    private enum CodingKeys: String, CodingKey {
        case id, actorType, actorId, actorDisplayName, message, messageParameters, messageType, deleted, timestamp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Lenient.int(container, .id) ?? 0
        actorType = try? container.decodeIfPresent(String.self, forKey: .actorType)
        actorId = try? container.decodeIfPresent(String.self, forKey: .actorId)
        actorDisplayName = try? container.decodeIfPresent(String.self, forKey: .actorDisplayName)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        messageType = try? container.decodeIfPresent(String.self, forKey: .messageType)
        deleted = Lenient.bool(container, .deleted)
        timestamp = Lenient.int(container, .timestamp)
        messageParameters = (try? container.decodeIfPresent([String: RichObjectDTO].self, forKey: .messageParameters)) ?? [:]
    }

    func model() -> ParentMessage {
        ParentMessage(
            messageID: id,
            actor: MessageActor(type: actorType ?? "users", id: actorId ?? "", displayName: actorDisplayName),
            text: message ?? "",
            parameters: messageParameters.objects,
            isDeleted: deleted ?? (messageType == "comment_deleted"),
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp ?? 0))
        )
    }
}
