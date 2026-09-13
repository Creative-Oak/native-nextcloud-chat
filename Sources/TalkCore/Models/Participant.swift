import Foundation

/// Someone in a conversation.
///
/// Fields verified against Talk's own OpenAPI description of the `Participant` schema.
struct Participant: Sendable, Hashable, Identifiable, Codable {
    var id: Int { attendeeID }

    var attendeeID: Int
    var actor: MessageActor
    var participantType: ParticipantType
    /// Combined final permissions, the same bitmask as on ``Conversation``.
    var permissions: ConversationPermissions
    var attendeePermissions: ConversationPermissions
    /// Last time this participant's session pinged; Talk recommends sorting by it.
    var lastPing: Date?
    /// In-call flags. `0` means not in the call.
    var inCall: Int
    /// Empty when the participant has no active session anywhere.
    var sessionIDs: [String]
    var status: UserStatus?
    /// Set when the participant was invited by a different identifier than they now use.
    var invitedActorID: String?

    var isOnline: Bool { !sessionIDs.isEmpty }
    var isInCall: Bool { inCall != 0 }
    var isModerator: Bool { participantType.isModerator }
    var displayName: String { actor.resolvedDisplayName }

    /// Owners and moderators first, then everyone else alphabetically — the order people
    /// expect in a participant list.
    static func listOrder(_ a: Participant, _ b: Participant) -> Bool {
        if a.isModerator != b.isModerator { return a.isModerator }
        if a.isOnline != b.isOnline { return a.isOnline }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    init(
        attendeeID: Int,
        actor: MessageActor,
        participantType: ParticipantType = .user,
        permissions: ConversationPermissions = [],
        attendeePermissions: ConversationPermissions = [],
        lastPing: Date? = nil,
        inCall: Int = 0,
        sessionIDs: [String] = [],
        status: UserStatus? = nil,
        invitedActorID: String? = nil
    ) {
        self.attendeeID = attendeeID
        self.actor = actor
        self.participantType = participantType
        self.permissions = permissions
        self.attendeePermissions = attendeePermissions
        self.lastPing = lastPing
        self.inCall = inCall
        self.sessionIDs = sessionIDs
        self.status = status
        self.invitedActorID = invitedActorID
    }
}

/// A person, group or team that can be invited — from Nextcloud's core autocomplete.
struct DirectoryEntry: Sendable, Hashable, Identifiable {
    enum Source: String, Sendable, Hashable {
        case users
        case groups
        case teams
        case circles
        case emails
        case federatedUsers = "federated_users"
        case phones
        case other

        init(rawValue: String) {
            switch rawValue {
            case "users": self = .users
            case "groups": self = .groups
            case "teams": self = .teams
            case "circles": self = .circles
            case "emails": self = .emails
            case "federated_users", "remotes": self = .federatedUsers
            case "phones": self = .phones
            default: self = .other
            }
        }

        /// What Talk's participant API calls this source.
        var talkSource: String {
            switch self {
            case .users: "users"
            case .groups: "groups"
            case .teams: "teams"
            case .circles: "circles"
            case .emails: "emails"
            case .federatedUsers: "federated_users"
            case .phones: "phones"
            case .other: "users"
            }
        }

        var symbolName: String {
            switch self {
            case .groups, .teams, .circles: "person.2"
            case .emails: "envelope"
            case .federatedUsers: "globe"
            case .phones: "phone"
            default: "person.crop.circle"
            }
        }
    }

    var id: String { "\(source.rawValue):\(identifier)" }

    var identifier: String
    var label: String
    var source: Source
    /// Secondary line, e.g. an email address, when two people share a name.
    var subline: String?
    var status: UserStatus?

    var isGroupLike: Bool {
        source == .groups || source == .teams || source == .circles
    }
}
