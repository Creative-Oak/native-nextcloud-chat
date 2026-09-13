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
    func hit() -> MessageSearchHit? {
        guard let token = attributes["conversation"], !token.isEmpty,
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
