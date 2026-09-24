import Foundation

/// Who said something. Talk models this as a (type, id) pair across users, guests, bots,
/// federated users and tombstones for deleted accounts.
struct MessageActor: Sendable, Hashable, Codable, Identifiable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case users
        case guests
        case bots
        case bridged
        case emails
        case groups
        case circles
        case federatedUsers = "federated_users"
        case deletedUsers = "deleted_users"
        case unknown

        init(rawValue: String) {
            switch rawValue {
            case "users": self = .users
            case "guests": self = .guests
            case "bots": self = .bots
            case "bridged": self = .bridged
            case "emails": self = .emails
            case "groups": self = .groups
            case "circles": self = .circles
            case "federated_users": self = .federatedUsers
            case "deleted_users": self = .deletedUsers
            default: self = .unknown
            }
        }
    }

    var kind: Kind
    var id: String
    var displayName: String

    /// What to actually show. Guests and deleted users routinely have an empty name.
    var resolvedDisplayName: String {
        if !displayName.isEmpty { return displayName }
        switch kind {
        case .guests: return String(localized: "Guest", comment: "Name shown for a guest who gave no name")
        case .deletedUsers: return String(localized: "Deleted user", comment: "Name shown for someone whose account was deleted")
        case .bots, .bridged: return id.isEmpty ? String(localized: "Bot", comment: "Name shown for a bot with no name") : id
        default: return id
        }
    }

    var isDeletedUser: Bool { kind == .deletedUsers }
    var isBot: Bool { kind == .bots || kind == .bridged }
    var isFederated: Bool { kind == .federatedUsers }

    /// Federated actor ids are cloud IDs (`user@server`); the local part is the user.
    var federationServer: String? {
        guard isFederated, let index = id.lastIndex(of: "@") else { return nil }
        return String(id[id.index(after: index)...])
    }

    init(kind: Kind, id: String, displayName: String = "") {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }

    init(type: String, id: String, displayName: String?) {
        self.init(kind: Kind(rawValue: type), id: id, displayName: displayName ?? "")
    }
}
