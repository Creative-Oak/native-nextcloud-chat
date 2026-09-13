import Foundation

/// Talk room types. Values verified against the Talk constants documentation.
enum ConversationType: Int, Sendable, Codable, CaseIterable {
    case oneToOne = 1
    case group = 2
    case publicRoom = 3
    case changelog = 4
    case formerOneToOne = 5
    case noteToSelf = 6

    /// Unknown future types degrade to `group`, which is the least surprising rendering.
    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .oneToOne
        case 2: self = .group
        case 3: self = .publicRoom
        case 4: self = .changelog
        case 5: self = .formerOneToOne
        case 6: self = .noteToSelf
        default: self = .group
        }
    }
}

enum ParticipantType: Int, Sendable, Codable {
    case owner = 1
    case moderator = 2
    case user = 3
    case guest = 4
    case userFollowingLink = 5
    case guestModerator = 6

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .owner
        case 2: self = .moderator
        case 3: self = .user
        case 4: self = .guest
        case 5: self = .userFollowingLink
        case 6: self = .guestModerator
        default: self = .user
        }
    }

    var isModerator: Bool { self == .owner || self == .moderator || self == .guestModerator }
}

enum NotificationLevel: Int, Sendable, Codable, CaseIterable, Identifiable {
    case `default` = 0
    case always = 1
    case mention = 2
    case never = 3

    var id: Int { rawValue }

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .always
        case 2: self = .mention
        case 3: self = .never
        default: self = .default
        }
    }

    var title: String {
        switch self {
        case .default: "Default"
        case .always: "All messages"
        case .mention: "@-mentions only"
        case .never: "Never"
        }
    }
}

/// Attendee permission bitmask. Verified values; see docs/NEXTCLOUD_API.md § 4.
struct ConversationPermissions: OptionSet, Sendable, Codable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let custom = ConversationPermissions(rawValue: 1)
    static let startCall = ConversationPermissions(rawValue: 2)
    static let joinCall = ConversationPermissions(rawValue: 4)
    static let ignoreLobby = ConversationPermissions(rawValue: 8)
    static let publishAudio = ConversationPermissions(rawValue: 16)
    static let publishVideo = ConversationPermissions(rawValue: 32)
    static let publishScreen = ConversationPermissions(rawValue: 64)
    static let postMessages = ConversationPermissions(rawValue: 128)
    static let addReactions = ConversationPermissions(rawValue: 256)

    /// `0` means "use the conversation default", which grants everything the room allows.
    var isDefault: Bool { rawValue == 0 }
}

/// A Talk conversation as this app understands it.
struct Conversation: Sendable, Hashable, Identifiable, Codable {
    var id: String { token }

    var token: String
    var numericID: Int
    var type: ConversationType
    var name: String
    var displayName: String
    var description: String

    var participantType: ParticipantType
    var attendeeID: Int
    var actor: MessageActor
    var permissions: ConversationPermissions
    var defaultPermissions: ConversationPermissions

    var isReadOnly: Bool
    var lobbyState: Int
    var lobbyTimer: Date?
    var messageExpiration: Int
    var hasPassword: Bool

    var hasCall: Bool
    var callFlag: Int
    var callStartTime: Date?
    var canStartCall: Bool

    var canDeleteConversation: Bool
    var canLeaveConversation: Bool

    var lastActivity: Date
    var isFavorite: Bool
    var isArchived: Bool
    var notificationLevel: NotificationLevel
    var notificationCalls: Int

    var unreadMessages: Int
    var unreadMention: Bool
    var unreadMentionDirect: Bool
    var lastReadMessageID: Int
    var lastCommonReadMessageID: Int
    var lastMessage: Message?

    var objectType: String
    var objectID: String
    var avatarVersion: String
    var hasCustomAvatar: Bool
    var mentionPermissions: Int

    var userStatus: UserStatus?

    // MARK: - Derived

    var isOneToOne: Bool { type == .oneToOne || type == .formerOneToOne }
    var isNoteToSelf: Bool { type == .noteToSelf }
    var isPublic: Bool { type == .publicRoom }

    /// The other participant's user id, for one-to-one avatars. Talk puts it in `name`.
    var oneToOnePartnerID: String? { isOneToOne ? name : nil }

    /// A former one-to-one is a conversation whose partner deleted their account. It still
    /// holds history, but nothing can be sent to it.
    var isFormerOneToOne: Bool { type == .formerOneToOne }

    var canPostMessages: Bool {
        guard !isReadOnly, !isFormerOneToOne else { return false }
        return permissions.isDefault || permissions.contains(.postMessages)
    }

    var canReact: Bool {
        guard !isReadOnly else { return false }
        return permissions.isDefault || permissions.contains(.addReactions)
    }

    var isModerator: Bool { participantType.isModerator }

    var hasUnread: Bool { unreadMessages > 0 }

    /// The lobby hides the conversation's content from non-moderators until it opens.
    var isLobbyBlocking: Bool { lobbyState == 1 && !isModerator }

    /// Sidebar ordering key. Favorites float, then most recent activity. Note to Self sits
    /// with everything else — pinning it above real conversations is a web-UI habit, not a
    /// Mac one.
    static func sidebarSort(_ a: Conversation, _ b: Conversation) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    /// Whether a new message here should raise a notification, per the user's server-side
    /// notification level for this conversation.
    func shouldNotify(forMention isMention: Bool) -> Bool {
        switch notificationLevel {
        case .never: false
        case .always: true
        case .mention: isMention
        case .default: isOneToOne ? true : isMention
        }
    }

    init(
        token: String,
        numericID: Int = 0,
        type: ConversationType = .group,
        name: String = "",
        displayName: String = "",
        description: String = "",
        participantType: ParticipantType = .user,
        attendeeID: Int = 0,
        actor: MessageActor = MessageActor(kind: .users, id: ""),
        permissions: ConversationPermissions = [],
        defaultPermissions: ConversationPermissions = [],
        isReadOnly: Bool = false,
        lobbyState: Int = 0,
        lobbyTimer: Date? = nil,
        messageExpiration: Int = 0,
        hasPassword: Bool = false,
        hasCall: Bool = false,
        callFlag: Int = 0,
        callStartTime: Date? = nil,
        canStartCall: Bool = false,
        canDeleteConversation: Bool = false,
        canLeaveConversation: Bool = true,
        lastActivity: Date = .distantPast,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        notificationLevel: NotificationLevel = .default,
        notificationCalls: Int = 1,
        unreadMessages: Int = 0,
        unreadMention: Bool = false,
        unreadMentionDirect: Bool = false,
        lastReadMessageID: Int = 0,
        lastCommonReadMessageID: Int = 0,
        lastMessage: Message? = nil,
        objectType: String = "",
        objectID: String = "",
        avatarVersion: String = "",
        hasCustomAvatar: Bool = false,
        mentionPermissions: Int = 0,
        userStatus: UserStatus? = nil
    ) {
        self.token = token
        self.numericID = numericID
        self.type = type
        self.name = name
        self.displayName = displayName
        self.description = description
        self.participantType = participantType
        self.attendeeID = attendeeID
        self.actor = actor
        self.permissions = permissions
        self.defaultPermissions = defaultPermissions
        self.isReadOnly = isReadOnly
        self.lobbyState = lobbyState
        self.lobbyTimer = lobbyTimer
        self.messageExpiration = messageExpiration
        self.hasPassword = hasPassword
        self.hasCall = hasCall
        self.callFlag = callFlag
        self.callStartTime = callStartTime
        self.canStartCall = canStartCall
        self.canDeleteConversation = canDeleteConversation
        self.canLeaveConversation = canLeaveConversation
        self.lastActivity = lastActivity
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.notificationLevel = notificationLevel
        self.notificationCalls = notificationCalls
        self.unreadMessages = unreadMessages
        self.unreadMention = unreadMention
        self.unreadMentionDirect = unreadMentionDirect
        self.lastReadMessageID = lastReadMessageID
        self.lastCommonReadMessageID = lastCommonReadMessageID
        self.lastMessage = lastMessage
        self.objectType = objectType
        self.objectID = objectID
        self.avatarVersion = avatarVersion
        self.hasCustomAvatar = hasCustomAvatar
        self.mentionPermissions = mentionPermissions
        self.userStatus = userStatus
    }
}

struct UserStatus: Sendable, Hashable, Codable {
    var status: String
    var icon: String?
    var message: String?
    var clearAt: Date?

    var isOnline: Bool { status == "online" }
    var isDoNotDisturb: Bool { status == "dnd" }
    var isAway: Bool { status == "away" }
}
