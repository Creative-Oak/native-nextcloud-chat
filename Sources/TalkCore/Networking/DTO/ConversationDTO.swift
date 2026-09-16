import Foundation

/// A Talk room from the v4 conversation API. See docs/NEXTCLOUD_API.md § 4.
///
/// Two decoding traps, both handled here:
/// 1. `lastMessage` is an object — except when the conversation has no messages, where it
///    is `[]`.
/// 2. Every capability-gated field is simply absent on servers that lack the capability,
///    so all of them are optional with documented defaults.
struct ConversationDTO: Decodable, Sendable {
    let id: Int
    let token: String
    let type: Int
    let name: String?
    let displayName: String?
    let description: String?
    let participantType: Int?
    let attendeeId: Int?
    let actorType: String?
    let actorId: String?
    let permissions: Int?
    let attendeePermissions: Int?
    let defaultPermissions: Int?
    let readOnly: Int?
    let listable: Int?
    let messageExpiration: Int?
    let hasPassword: Bool?
    let hasCall: Bool?
    let callFlag: Int?
    let callStartTime: Int?
    let canStartCall: Bool?
    let canDeleteConversation: Bool?
    let canLeaveConversation: Bool?
    let lastActivity: Int?
    let isFavorite: Bool?
    let isArchived: Bool?
    let isImportant: Bool?
    let isSensitive: Bool?
    let notificationLevel: Int?
    let notificationCalls: Int?
    let lobbyState: Int?
    let lobbyTimer: Int?
    let unreadMessages: Int?
    let unreadMention: Bool?
    let unreadMentionDirect: Bool?
    let lastReadMessage: Int?
    let lastCommonReadMessage: Int?
    let lastMessage: MessageDTO?
    let objectType: String?
    let objectId: String?
    let avatarVersion: String?
    let isCustomAvatar: Bool?
    let mentionPermissions: Int?
    let status: String?
    let statusIcon: String?
    let statusMessage: String?
    let statusClearAt: Int?

    private enum CodingKeys: String, CodingKey {
        case id, token, type, name, displayName, description, participantType, attendeeId
        case actorType, actorId, permissions, attendeePermissions, defaultPermissions
        case readOnly, listable, messageExpiration, hasPassword, hasCall, callFlag, callStartTime
        case canStartCall, canDeleteConversation, canLeaveConversation, lastActivity
        case isFavorite, isArchived, isImportant, isSensitive, notificationLevel, notificationCalls, lobbyState, lobbyTimer
        case unreadMessages, unreadMention, unreadMentionDirect, lastReadMessage, lastCommonReadMessage
        case lastMessage, objectType, objectId, avatarVersion, isCustomAvatar, mentionPermissions
        case status, statusIcon, statusMessage, statusClearAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        id = Lenient.int(container, .id) ?? 0
        type = Lenient.int(container, .type) ?? 2
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        participantType = Lenient.int(container, .participantType)
        attendeeId = Lenient.int(container, .attendeeId)
        actorType = try? container.decodeIfPresent(String.self, forKey: .actorType)
        actorId = try? container.decodeIfPresent(String.self, forKey: .actorId)
        permissions = Lenient.int(container, .permissions)
        attendeePermissions = Lenient.int(container, .attendeePermissions)
        defaultPermissions = Lenient.int(container, .defaultPermissions)
        readOnly = Lenient.int(container, .readOnly)
        listable = Lenient.int(container, .listable)
        messageExpiration = Lenient.int(container, .messageExpiration)
        hasPassword = Lenient.bool(container, .hasPassword)
        hasCall = Lenient.bool(container, .hasCall)
        callFlag = Lenient.int(container, .callFlag)
        callStartTime = Lenient.int(container, .callStartTime)
        canStartCall = Lenient.bool(container, .canStartCall)
        canDeleteConversation = Lenient.bool(container, .canDeleteConversation)
        canLeaveConversation = Lenient.bool(container, .canLeaveConversation)
        lastActivity = Lenient.int(container, .lastActivity)
        isFavorite = Lenient.bool(container, .isFavorite)
        isArchived = Lenient.bool(container, .isArchived)
        isImportant = Lenient.bool(container, .isImportant)
        isSensitive = Lenient.bool(container, .isSensitive)
        notificationLevel = Lenient.int(container, .notificationLevel)
        notificationCalls = Lenient.int(container, .notificationCalls)
        lobbyState = Lenient.int(container, .lobbyState)
        lobbyTimer = Lenient.int(container, .lobbyTimer)
        unreadMessages = Lenient.int(container, .unreadMessages)
        unreadMention = Lenient.bool(container, .unreadMention)
        unreadMentionDirect = Lenient.bool(container, .unreadMentionDirect)
        lastReadMessage = Lenient.int(container, .lastReadMessage)
        lastCommonReadMessage = Lenient.int(container, .lastCommonReadMessage)
        objectType = try? container.decodeIfPresent(String.self, forKey: .objectType)
        objectId = Lenient.string(container, .objectId)
        avatarVersion = try? container.decodeIfPresent(String.self, forKey: .avatarVersion)
        isCustomAvatar = Lenient.bool(container, .isCustomAvatar)
        mentionPermissions = Lenient.int(container, .mentionPermissions)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        statusIcon = try? container.decodeIfPresent(String.self, forKey: .statusIcon)
        statusMessage = try? container.decodeIfPresent(String.self, forKey: .statusMessage)
        statusClearAt = Lenient.int(container, .statusClearAt)

        // `[]` when the conversation has never had a message.
        lastMessage = try? container.decodeIfPresent(MessageDTO.self, forKey: .lastMessage)
    }

    func model() -> Conversation {
        var userStatus: UserStatus?
        if let status, !status.isEmpty {
            userStatus = UserStatus(
                status: status,
                icon: statusIcon,
                message: statusMessage,
                clearAt: statusClearAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }

        // `permissions` is the combined final value Talk computed for us; fall back to the
        // attendee-specific value when an older server omits it.
        let effectivePermissions = permissions ?? attendeePermissions ?? 0

        return Conversation(
            token: token,
            numericID: id,
            type: ConversationType(rawValue: type),
            name: name ?? "",
            displayName: displayName ?? name ?? "",
            description: description ?? "",
            participantType: ParticipantType(rawValue: participantType ?? 3),
            attendeeID: attendeeId ?? 0,
            actor: MessageActor(type: actorType ?? "users", id: actorId ?? "", displayName: nil),
            permissions: ConversationPermissions(rawValue: effectivePermissions),
            defaultPermissions: ConversationPermissions(rawValue: defaultPermissions ?? 0),
            isReadOnly: (readOnly ?? 0) == 1,
            lobbyState: lobbyState ?? 0,
            lobbyTimer: (lobbyTimer ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(lobbyTimer ?? 0)) : nil,
            messageExpiration: messageExpiration ?? 0,
            hasPassword: hasPassword ?? false,
            hasCall: hasCall ?? false,
            callFlag: callFlag ?? 0,
            callStartTime: (callStartTime ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(callStartTime ?? 0)) : nil,
            canStartCall: canStartCall ?? false,
            canDeleteConversation: canDeleteConversation ?? false,
            canLeaveConversation: canLeaveConversation ?? true,
            lastActivity: Date(timeIntervalSince1970: TimeInterval(lastActivity ?? 0)),
            isFavorite: isFavorite ?? false,
            isArchived: isArchived ?? false,
            notificationLevel: NotificationLevel(rawValue: notificationLevel ?? 0),
            notificationCalls: notificationCalls ?? 1,
            isImportant: isImportant ?? false,
            isSensitive: isSensitive ?? false,
            unreadMessages: unreadMessages ?? 0,
            unreadMention: unreadMention ?? false,
            // Without `direct-mention-flag` the server can't distinguish @all from a direct
            // mention, so the coarse flag is the best truth available.
            unreadMentionDirect: unreadMentionDirect ?? (unreadMention ?? false),
            lastReadMessageID: lastReadMessage ?? 0,
            lastCommonReadMessageID: lastCommonReadMessage ?? 0,
            lastMessage: lastMessage?.model(token: token),
            objectType: objectType ?? "",
            objectID: objectId ?? "",
            avatarVersion: avatarVersion ?? "",
            hasCustomAvatar: isCustomAvatar ?? false,
            mentionPermissions: mentionPermissions ?? 0,
            userStatus: userStatus
        )
    }
}
