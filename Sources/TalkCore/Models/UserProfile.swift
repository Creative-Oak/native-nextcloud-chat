import Foundation

/// Who can see a profile field. Nextcloud's own four, in widening order.
enum ProfileScope: String, Sendable, Hashable, CaseIterable {
    case `private` = "v2-private"
    case local = "v2-local"
    case federated = "v2-federated"
    case published = "v2-published"

    /// Accepts the names servers used before the `v2-` scopes, so an old server's profile
    /// still says something rather than nothing.
    init?(serverValue: String) {
        if let scope = ProfileScope(rawValue: serverValue) {
            self = scope
            return
        }
        switch serverValue {
        case "private": self = .private
        case "contacts": self = .local
        case "public": self = .published
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .private: String(localized: "Private", comment: "Profile field visibility")
        case .local: String(localized: "Local", comment: "Profile field visibility")
        case .federated: String(localized: "Federated", comment: "Profile field visibility")
        case .published: String(localized: "Published", comment: "Profile field visibility")
        }
    }

    var explanation: String {
        switch self {
        case .private: String(localized: "Only people you share with, and trusted servers")
        case .local: String(localized: "Only people on your server")
        case .federated: String(localized: "People on your server and trusted servers")
        case .published: String(localized: "Anyone, including search")
        }
    }
}

/// One property on the Personal info page.
struct ProfileField: Sendable, Hashable, Identifiable {
    /// Every field a user edits on the Personal info page, in the order it shows them.
    enum Kind: String, Sendable, CaseIterable {
        case email, phone, address, website, pronouns, headline, organisation, role
        case biography, fediverse, bluesky, twitter, birthdate

        var title: String {
            switch self {
            case .email: String(localized: "Email", comment: "Profile field")
            case .phone: String(localized: "Phone", comment: "Profile field: phone number")
            case .address: String(localized: "Location", comment: "Profile field: where the person is")
            case .website: String(localized: "Website", comment: "Profile field")
            case .pronouns: String(localized: "Pronouns", comment: "Profile field")
            case .headline: String(localized: "Headline", comment: "Profile field: a one-line professional title")
            case .organisation: String(localized: "Organisation", comment: "Profile field")
            case .role: String(localized: "Role", comment: "Profile field: job role")
            case .biography: String(localized: "About", comment: "Profile field: the person’s biography")
            case .fediverse: "Fediverse"
            case .bluesky: "Bluesky"
            case .twitter: "X"
            case .birthdate: String(localized: "Birthday", comment: "Profile field")
            }
        }

        /// Long enough to want room of its own rather than a single line beside its label.
        var isMultiline: Bool { self == .biography }
    }

    var id: Kind { kind }
    let kind: Kind
    let value: String
    let scope: ProfileScope?
}

/// What the Personal info page holds, as the signed-in user sees it.
///
/// Read-only in this app, by necessity rather than by choice: editing goes through
/// `PUT /cloud/users/{userId}`, which requires a password confirmed in the last half hour,
/// and a request made with an app password never has one.
struct UserProfile: Sendable, Hashable {
    let userID: String
    let displayName: String
    /// Only the fields that have a value, in ``ProfileField/Kind`` order.
    let fields: [ProfileField]
    /// Whether the public profile page at `/u/{userId}` exists for other people to see.
    let isProfileEnabled: Bool

    func field(_ kind: ProfileField.Kind) -> ProfileField? {
        fields.first { $0.kind == kind }
    }
}

/// `GET /ocs/v2.php/cloud/users/{userId}`, where every property comes with a sibling
/// `{property}Scope`.
struct UserProfileDTO: Decodable, Sendable {
    let profile: UserProfile

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let id = Lenient.string(container, Key("id")) ?? ""
        let displayName = Lenient.string(container, Key("displayname"))
            ?? Lenient.string(container, Key("display-name"))
            ?? id

        let fields = ProfileField.Kind.allCases.compactMap { kind -> ProfileField? in
            guard let value = Lenient.string(container, Key(kind.rawValue))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { return nil }
            let scope = Lenient.string(container, Key(kind.rawValue + "Scope")).flatMap(ProfileScope.init(serverValue:))
            return ProfileField(kind: kind, value: value, scope: scope)
        }

        profile = UserProfile(
            userID: id,
            displayName: displayName,
            fields: fields,
            isProfileEnabled: Lenient.bool(container, Key("profile_enabled")) ?? false
        )
    }
}
