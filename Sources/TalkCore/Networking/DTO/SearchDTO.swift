import Foundation

/// Nextcloud core's unified search response.
///
/// Shapes verified against `core/openapi.json` (`UnifiedSearchResult`,
/// `UnifiedSearchResultEntry`, `UnifiedSearchProvider`) with one correction: the
/// description types `attributes` as an array of strings, but the server builds it with
/// `SearchResultEntry::addAttribute($key, $value)` into a PHP associative array, which
/// serializes as an object. It is decoded as a map, tolerating the `[]` PHP produces when
/// a provider adds none.
struct UnifiedSearchResultDTO: Decodable, Sendable {
    var name: String
    var isPaginated: Bool
    var entries: [UnifiedSearchEntryDTO]
    /// `int | string | null` in the description — kept as text so it can be echoed back
    /// without being reinterpreted.
    var cursor: String?

    private enum CodingKeys: String, CodingKey {
        case name, isPaginated, entries, cursor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = Lenient.string(container, .name) ?? ""
        isPaginated = Lenient.bool(container, .isPaginated) ?? false
        entries = (try? container.decodeIfPresent([UnifiedSearchEntryDTO].self, forKey: .entries)) ?? []
        cursor = Lenient.string(container, .cursor)
    }
}

struct UnifiedSearchEntryDTO: Decodable, Sendable {
    var thumbnailUrl: String
    var title: String
    var subline: String
    var resourceUrl: String
    var icon: String
    var rounded: Bool
    @EmptyArrayTolerantDictionary var attributes: [String: String]

    private enum CodingKeys: String, CodingKey {
        case thumbnailUrl, title, subline, resourceUrl, icon, rounded, attributes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thumbnailUrl = Lenient.string(container, .thumbnailUrl) ?? ""
        title = Lenient.string(container, .title) ?? ""
        subline = Lenient.string(container, .subline) ?? ""
        resourceUrl = Lenient.string(container, .resourceUrl) ?? ""
        icon = Lenient.string(container, .icon) ?? ""
        rounded = Lenient.bool(container, .rounded) ?? false
        _attributes = try container.decode(EmptyArrayTolerantDictionary<String>.self, forKey: .attributes)
    }

    /// Talk's `talk-message` provider attaches these. A hit without a conversation token
    /// or a message id can't be navigated to, so it is dropped rather than shown.
    ///
    /// `attributes` is a free-form string map that any search provider on the server can
    /// fill in, and this is the one place where a value out of it becomes a conversation
    /// token the app then navigates to, long-polls and writes read markers into. A token
    /// that is not shaped like a token is dropped here rather than carried into a URL.
    func hit() -> MessageSearchHit? {
        guard let token = attributes["conversation"], Self.isPlausibleToken(token),
              let messageID = attributes["messageId"].flatMap(Int.init), messageID > 0
        else { return nil }

        let seconds = attributes["timestamp"].flatMap(Double.init) ?? 0
        return MessageSearchHit(
            token: token,
            messageID: messageID,
            threadID: attributes["threadId"].flatMap(Int.init),
            actorType: attributes["actorType"] ?? "",
            actorID: attributes["actorId"] ?? "",
            title: title,
            snippet: subline,
            timestamp: Date(timeIntervalSince1970: seconds),
            avatarURL: thumbnailUrl.isEmpty ? nil : URL(string: thumbnailUrl),
            resourceURL: resourceUrl.isEmpty ? nil : URL(string: resourceUrl)
        )
    }

    /// Talk generates room tokens from an alphanumeric alphabet. `-` and `_` are tolerated
    /// because they are URL-safe and a future token format may use them; anything else —
    /// a slash, a dot, a percent — is not a token, whatever the server calls it.
    static func isPlausibleToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 64
            && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

struct UnifiedSearchProviderDTO: Decodable, Sendable {
    var id: String
    var appId: String
    var name: String
    @EmptyArrayTolerantDictionary var filters: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id, appId, name, filters
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Lenient.string(container, .id) ?? ""
        appId = Lenient.string(container, .appId) ?? ""
        name = Lenient.string(container, .name) ?? ""
        _filters = try container.decode(EmptyArrayTolerantDictionary<String>.self, forKey: .filters)
    }
}
