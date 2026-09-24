import Foundation

/// A message pinned to the top of a conversation.
struct PinnedMessage: Sendable, Hashable, Identifiable {
    var message: Message
    var pinnedAt: Date
    /// When the pin lifts itself. Nil means it stays until a moderator unpins it.
    var pinnedUntil: Date?
    var pinnedBy: MessageActor

    var id: Int { message.messageID }

    func isActive(at now: Date = Date()) -> Bool {
        pinnedUntil.map { $0 > now } ?? true
    }
}

/// How long a pin lasts, as the message menu offers it.
enum PinDuration: CaseIterable, Sendable, Identifiable {
    case day, week, month, untilUnpinned

    var id: Self { self }

    var title: String {
        switch self {
        case .day: String(localized: "For 24 Hours", comment: "How long to pin a message")
        case .week: String(localized: "For 7 Days", comment: "How long to pin a message")
        case .month: String(localized: "For 30 Days", comment: "How long to pin a message")
        case .untilUnpinned: String(localized: "Until Unpinned", comment: "How long to pin a message: until someone unpins it")
        }
    }

    func until(from now: Date = Date()) -> Date? {
        switch self {
        case .day: now.addingTimeInterval(24 * 60 * 60)
        case .week: now.addingTimeInterval(7 * 24 * 60 * 60)
        case .month: now.addingTimeInterval(30 * 24 * 60 * 60)
        case .untilUnpinned: nil
        }
    }
}

/// Pinned messages. Cap `pinned-messages`. Pinning and unpinning are for moderators; anyone
/// can hide the pinned bar for themselves, until something newer is pinned.
///
/// There is no endpoint that lists pins as such: they are a kind of shared item,
/// `objectType=pinned`, and each carries when and by whom in its `metaData`.
actor PinService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// Every pin in the conversation, most recently pinned first.
    func pinnedMessages(token: String) async throws(TalkError) -> [PinnedMessage] {
        let query = [
            URLQueryItem(name: "objectType", value: "pinned"),
            URLQueryItem(name: "limit", value: "50")
        ]
        // Keyed by message id, like every single-type shared items listing.
        let response = try await client.send(
            OCSRequest.get(Endpoint.sharedItems(token), query: query),
            as: [String: PinnedMessageDTO].self
        )
        return (response.value ?? [:]).values
            .map { $0.model(token: token) }
            .sorted { $0.pinnedAt > $1.pinnedAt }
    }

    func pin(token: String, messageID: Int, until: Date?) async throws(TalkError) {
        var form: [String: String] = [:]
        if let until { form["pinUntil"] = String(Int(until.timeIntervalSince1970)) }
        _ = try await client.send(OCSRequest.post(Endpoint.pin(token, messageID), form: form), as: EmptyResponse.self)
    }

    func unpin(token: String, messageID: Int) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.pin(token, messageID)), as: EmptyResponse.self)
    }

    /// Hides the pinned bar for this user until a newer message is pinned.
    func hideForMe(token: String, messageID: Int) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.pinSelf(token, messageID)), as: EmptyResponse.self)
    }
}

/// A shared item of type `pinned`: an ordinary message, plus who pinned it and when.
struct PinnedMessageDTO: Decodable, Sendable {
    let message: MessageDTO
    let metaData: MetaData?

    struct MetaData: Decodable, Sendable {
        let pinnedActorType: String?
        let pinnedActorId: String?
        let pinnedActorDisplayName: String?
        let pinnedAt: Int?
        let pinnedUntil: Int?

        private enum CodingKeys: String, CodingKey {
            case pinnedActorType, pinnedActorId, pinnedActorDisplayName, pinnedAt, pinnedUntil
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pinnedActorType = try? container.decodeIfPresent(String.self, forKey: .pinnedActorType)
            pinnedActorId = Lenient.string(container, .pinnedActorId)
            pinnedActorDisplayName = try? container.decodeIfPresent(String.self, forKey: .pinnedActorDisplayName)
            pinnedAt = Lenient.int(container, .pinnedAt)
            pinnedUntil = Lenient.int(container, .pinnedUntil)
        }
    }

    private enum CodingKeys: String, CodingKey { case metaData }

    init(from decoder: any Decoder) throws {
        message = try MessageDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `[]` when empty, as PHP serializes an empty map.
        metaData = try? container.decodeIfPresent(MetaData.self, forKey: .metaData)
    }

    func model(token: String) -> PinnedMessage {
        let message = message.model(token: token)
        let until = metaData?.pinnedUntil ?? 0
        return PinnedMessage(
            message: message,
            pinnedAt: Date(timeIntervalSince1970: TimeInterval(metaData?.pinnedAt ?? 0)),
            pinnedUntil: until > 0 ? Date(timeIntervalSince1970: TimeInterval(until)) : nil,
            pinnedBy: MessageActor(
                type: metaData?.pinnedActorType ?? "users",
                id: metaData?.pinnedActorId ?? "",
                displayName: metaData?.pinnedActorDisplayName
            )
        )
    }
}
