import Foundation

struct ServerVersion: Sendable, Hashable, Codable {
    var major: Int
    var minor: Int
    var micro: Int
    var string: String
    var edition: String

    static let unknown = ServerVersion(major: 0, minor: 0, micro: 0, string: "unknown", edition: "")
}

/// Everything the client is allowed to assume about a server, expressed as capabilities
/// rather than version numbers.
///
/// There is exactly one rule: **no feature decision anywhere in this app compares version
/// numbers.** If a server does not advertise a capability, the affordance is hidden.
struct TalkCapabilities: Sendable, Hashable, Codable {
    /// Raw capability strings, kept verbatim so nothing is lost when the server is newer than us.
    var features: Set<String>
    var config: TalkConfig
    /// The Talk app version, for display in Settings → Accounts only.
    var talkVersion: String?
    var serverVersion: ServerVersion
    /// The `user_status` app. Nil when it is not installed or turned off, which hides status
    /// everywhere rather than showing controls the server will refuse.
    var userStatus: UserStatusSupport?

    init(
        features: Set<String> = [],
        config: TalkConfig = TalkConfig(),
        talkVersion: String? = nil,
        serverVersion: ServerVersion = .unknown,
        userStatus: UserStatusSupport? = nil
    ) {
        self.features = features
        self.config = config
        self.talkVersion = talkVersion
        self.serverVersion = serverVersion
        self.userStatus = userStatus
    }

    func has(_ feature: String) -> Bool { features.contains(feature) }

    // MARK: - Named capabilities
    //
    // Every one of these maps to a documented capability string; see docs/NEXTCLOUD_API.md § 3.

    /// The minimum bar. Without this the server is too old to talk to at all.
    var supportsChat: Bool { has("chat-v2") }

    var canSetReadMarker: Bool { has("chat-read-marker") }
    var canMarkUnread: Bool { has("chat-unread") }
    var showsReadStatus: Bool { has("chat-read-status") }
    var supportsReferenceIDs: Bool { has("chat-reference-id") }
    var supportsReplies: Bool { has("chat-replies") }
    /// A reply in a one-to-one can quote a message from a group conversation you share.
    var supportsPrivateReply: Bool { has("private-reply") }
    var supportsMessageContext: Bool { has("chat-get-context") }
    var supportsReactions: Bool { has("reactions") }
    var supportsMarkdown: Bool { has("markdown-messages") }
    var supportsSilentSend: Bool { has("silent-send") }
    var showsSilentState: Bool { has("silent-send-state") }
    var supportsMessageExpiration: Bool { has("message-expiration") }
    var supportsMentionFlag: Bool { has("mention-flag") }
    var supportsDirectMentionFlag: Bool { has("direct-mention-flag") }
    var supportsMentionPermissions: Bool { has("mention-permissions") }
    var supportsFavorites: Bool { has("favorites") }
    var supportsNotificationLevels: Bool { has("notification-levels") }
    var supportsConversationAvatars: Bool { has("avatar") }
    var supportsNoteToSelf: Bool { has("note-to-self") }
    var supportsArchive: Bool { has("archived-conversations-v2") }
    var supportsImportantConversations: Bool { has("important-conversations") }
    var supportsSensitiveConversations: Bool { has("sensitive-conversations") }
    var supportsConversationPermissions: Bool { has("conversation-permissions") }
    var supportsSessionState: Bool { has("session-state") }
    var supportsReminders: Bool { has("remind-me-later") }
    var supportsUpcomingReminders: Bool { has("upcoming-reminders") }
    var supportsScheduledMessages: Bool { has("scheduled-messages") }
    var supportsClearHistory: Bool { has("clear-history") }
    var supportsSharedItems: Bool { has("rich-object-list-media") }
    var supportsFederation: Bool { has("federation-v1") || has("federation-v2") }
    var supportsPolls: Bool { has("talk-polls") }
    var supportsTypingIndicators: Bool { has("typing-privacy") }
    var supportsPinnedMessages: Bool { has("pinned-messages") }

    var canEditMessages: Bool { has("edit-messages") }
    /// Talk 20 allows editing in Note to Self even where general editing is unavailable.
    var canEditNoteToSelfMessages: Bool { canEditMessages || has("edit-messages-note-to-self") }
    var canDeleteMessages: Bool { has("delete-messages") }
    /// Talk 19 lifted the six-hour deletion window.
    var deletionIsTimeLimited: Bool { canDeleteMessages && !has("delete-messages-unlimited") }
    var canDeleteRichObjectMessages: Bool { has("rich-object-delete") }

    var canCreateConversations: Bool { config.conversationsCanCreate ?? true }
    var attachmentsAllowed: Bool { config.attachmentsAllowed ?? false }

    /// The six-hour window Talk enforces server-side for deletions on older servers.
    static let deletionWindow: TimeInterval = 6 * 60 * 60

    func canDelete(_ message: Message, now: Date = Date()) -> Bool {
        guard canDeleteMessages, message.isDeletable else { return false }
        guard deletionIsTimeLimited else { return true }
        return now.timeIntervalSince(message.timestamp) < Self.deletionWindow
    }

    static let empty = TalkCapabilities()
}

/// What the server's `user_status` app offers.
struct UserStatusSupport: Sendable, Hashable, Codable {
    var supportsEmoji: Bool
    var supportsBusy: Bool
}

struct TalkConfig: Sendable, Hashable, Codable {
    var chatMaxLength: Int?
    /// `0` public, `1` private. Read receipts only mean something when public.
    var chatReadPrivacy: Int?
    var chatTypingPrivacy: Int?
    var attachmentsAllowed: Bool?
    var attachmentsFolder: String?
    var conversationsCanCreate: Bool?
    var previewsMaxGIFSize: Int?
    var callEnabled: Bool?

    /// Talk's own default when the server doesn't say.
    var effectiveMaxMessageLength: Int { chatMaxLength ?? 32_000 }
    var readReceiptsAreMeaningful: Bool { (chatReadPrivacy ?? 1) == 0 }
}
