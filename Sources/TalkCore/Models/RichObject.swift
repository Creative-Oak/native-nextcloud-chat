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

    /// Where this object lives — and only ever somewhere a browser goes.
    ///
    /// A rich object comes off the wire, so `link` is a string the server picked, and
    /// every reader of this property either opens it or makes it clickable under a label
    /// the server also picked. Three of those readers say "Open in Nextcloud" while they
    /// do it. So a destination this app would not open is not a link at all, and the
    /// affordance never appears: validating here rather than at each sink is what keeps a
    /// sixth sink, added later, safe by default.
    var link: URL? {
        guard let url = attributes["link"].flatMap(URL.init(string:)), url.isWebLink else { return nil }
        return url
    }
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

    /// The name as it is shown. A name is server text and is read as a claim — whose file
    /// this is, who is being addressed — so the characters that could reorder or hide the
    /// words around it are not part of it. See ``Swift/String/withoutInvisibleMarks``.
    var displayName: String { name.withoutInvisibleMarks }

    var isImage: Bool { mimeType?.hasPrefix("image/") ?? false }
    var isVideo: Bool { mimeType?.hasPrefix("video/") ?? false }
    /// A voice message or any other sound file — played in the transcript.
    var isAudio: Bool { mimeType?.hasPrefix("audio/") ?? false }

    /// Mentions of the current user come through as `type: user` with a matching id, but
    /// `{mention-call}` (i.e. `@all`) is a `call` object — both highlight.
    var isMentionable: Bool {
        switch type {
        case .user, .userGroup, .call, .guest, .circle, .email: true
        default: false
        }
    }
}

extension RichObject {
    /// Whether this is a shape rather than a row: a picture we can actually draw, or a poll.
    /// Those get no message bubble — see ``MessageContent/standalone``.
    var drawsItsOwnShape: Bool {
        type == .talkPoll || (isImage && previewAvailable)
    }
}
