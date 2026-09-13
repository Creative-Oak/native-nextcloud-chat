import Foundation

/// One entry of `messageParameters`.
///
/// The parameter set is documented in `lib/public/RichObjectStrings/Definitions.php`
/// (see docs/NEXTCLOUD_API.md § 6). Unknown types are preserved rather than dropped, and
/// render as their `name`, so a message from a newer server degrades to readable text
/// instead of protocol gibberish.
struct RichObject: Sendable, Hashable, Codable {
    enum Kind: Sendable, Hashable, Codable {
        case user
        case guest
        case userGroup
        case call
        case file
        case geoLocation
        case talkPoll
        case talkAttachment
        case deckCard
        case highlight
        case email
        case circle
        case openGraph
        case other(String)

        init(rawValue: String) {
            switch rawValue {
            case "user": self = .user
            case "guest": self = .guest
            case "user-group", "group": self = .userGroup
            case "call": self = .call
            case "file": self = .file
            case "geo-location": self = .geoLocation
            case "talk-poll": self = .talkPoll
            case "talk-attachment": self = .talkAttachment
            case "deck-card": self = .deckCard
            case "highlight": self = .highlight
            case "email": self = .email
            case "circle": self = .circle
            case "open-graph": self = .openGraph
            default: self = .other(rawValue)
            }
        }

        var rawValue: String {
            switch self {
            case .user: "user"
            case .guest: "guest"
            case .userGroup: "user-group"
            case .call: "call"
            case .file: "file"
            case .geoLocation: "geo-location"
            case .talkPoll: "talk-poll"
            case .talkAttachment: "talk-attachment"
            case .deckCard: "deck-card"
            case .highlight: "highlight"
            case .email: "email"
            case .circle: "circle"
            case .openGraph: "open-graph"
            case .other(let value): value
            }
        }
    }

    var type: Kind
    var id: String
    var name: String
    /// Remaining keys, verbatim. Typed accessors below cover the ones we use.
    var attributes: [String: String]

    init(type: Kind, id: String, name: String, attributes: [String: String] = [:]) {
        self.type = type
        self.id = id
        self.name = name
        self.attributes = attributes
    }

    // Typed accessors for the keys this app actually reads.
    var server: String? { attributes["server"] }
    var link: URL? { attributes["link"].flatMap(URL.init(string:)) }
    var path: String? { attributes["path"] }
    var mimeType: String? { attributes["mimetype"] }
    var size: Int? { attributes["size"].flatMap(Int.init) }
    var width: Int? { attributes["width"].flatMap(Int.init) }
    var height: Int? { attributes["height"].flatMap(Int.init) }
    var blurhash: String? { attributes["blurhash"] }
    var previewAvailable: Bool { attributes["preview-available"] == "yes" || attributes["preview-available"] == "true" }
    var latitude: Double? { attributes["latitude"].flatMap(Double.init) }
    var longitude: Double? { attributes["longitude"].flatMap(Double.init) }
    var callType: String? { attributes["call-type"] }
    var boardName: String? { attributes["boardname"] }
    var stackName: String? { attributes["stackname"] }

    var isImage: Bool { mimeType?.hasPrefix("image/") ?? false }
    var isVideo: Bool { mimeType?.hasPrefix("video/") ?? false }

    /// Mentions of the current user come through as `type: user` with a matching id, but
    /// `{mention-call}` (i.e. `@all`) is a `call` object — both highlight.
    var isMentionable: Bool {
        switch type {
        case .user, .userGroup, .call, .guest, .circle, .email: true
        default: false
        }
    }
}
