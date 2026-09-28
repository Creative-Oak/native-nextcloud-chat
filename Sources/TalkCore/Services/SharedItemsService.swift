import Foundation

/// The kinds of thing Talk tracks as "shared" in a conversation.
enum SharedItemType: String, Sendable, Hashable, CaseIterable, Identifiable {
    case media
    case file
    case voice
    case audio
    case location
    case deckcard
    case poll
    case recording
    /// Pinned messages. Listed as a shared item by the server, shown by the pinned bar
    /// rather than the inspector — which is why it is left out of `displayOrder`.
    case pinned
    case other

    var id: String { rawValue }

    init(rawValue: String) {
        switch rawValue {
        case "media": self = .media
        case "file": self = .file
        case "voice": self = .voice
        case "audio": self = .audio
        case "location": self = .location
        case "deckcard": self = .deckcard
        case "poll": self = .poll
        case "recording": self = .recording
        case "pinned": self = .pinned
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .media: String(localized: "Media", comment: "Shared items category heading")
        case .file: String(localized: "Files", comment: "Shared items category heading")
        case .voice: String(localized: "Voice Messages", comment: "Shared items category heading")
        case .audio: String(localized: "Audio", comment: "Shared items category heading")
        case .location: String(localized: "Locations", comment: "Shared items category heading")
        case .deckcard: String(localized: "Deck Cards", comment: "Shared items category heading: cards from the Nextcloud Deck app")
        case .poll: String(localized: "Polls", comment: "Shared items category heading")
        case .recording: String(localized: "Recordings", comment: "Shared items category heading")
        case .pinned: String(localized: "Pinned", comment: "Shared items category heading: pinned messages")
        case .other: String(localized: "Other", comment: "Shared items category heading")
        }
    }

    var symbolName: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .file: "doc"
        case .voice: "waveform"
        case .audio: "music.note"
        case .location: "mappin.and.ellipse"
        case .deckcard: "rectangle.stack"
        case .poll: "chart.bar"
        case .recording: "record.circle"
        case .pinned: "pin"
        case .other: "tray"
        }
    }

    /// The order the inspector shows them in — most useful first.
    static let displayOrder: [SharedItemType] = [.media, .file, .voice, .audio, .location, .poll, .deckcard, .recording, .other]
}

/// Everything shared into a conversation, for the inspector's Files tab.
///
/// Requires the `rich-object-list-media` capability. Two response shapes, both verified
/// against Talk's OpenAPI description and both surprising:
/// - the overview is a **map of type → array of messages**
/// - a single type's listing is a **map of message id → message**, not an array
actor SharedItemsService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// A few of each kind, for the tab headers.
    func overview(token: String, limit: Int = 7) async throws(TalkError) -> [SharedItemType: [Message]] {
        let query = [URLQueryItem(name: "limit", value: String(limit))]
        let response = try await client.send(
            OCSRequest.get(Endpoint.sharedItemsOverview(token), query: query),
            as: [String: [MessageDTO]].self
        )

        var result: [SharedItemType: [Message]] = [:]
        for (rawType, messages) in response.value ?? [:] where !messages.isEmpty {
            result[SharedItemType(rawValue: rawType)] = messages
                .map { $0.model(token: token) }
                .sorted { $0.messageID > $1.messageID }
        }
        return result
    }

    /// One kind, paged. Newest first, which is how the inspector shows them.
    func items(
        token: String,
        type: SharedItemType,
        lastKnownMessageID: Int? = nil,
        limit: Int = 100
    ) async throws(TalkError) -> [Message] {
        var query = [
            URLQueryItem(name: "objectType", value: type.rawValue),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let lastKnownMessageID, lastKnownMessageID > 0 {
            query.append(URLQueryItem(name: "lastKnownMessageId", value: String(lastKnownMessageID)))
        }

        // Keyed by message id, not an array.
        let response = try await client.send(
            OCSRequest.get(Endpoint.sharedItems(token), query: query),
            as: [String: MessageDTO].self
        )
        return (response.value ?? [:])
            .values
            .map { $0.model(token: token) }
            .sorted { $0.messageID > $1.messageID }
    }
}
