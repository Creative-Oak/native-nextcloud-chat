import Foundation

/// The reaction map for a message: emoji → who reacted.
struct ReactionSummary: Sendable, Equatable {
    var counts: [String: Int]
    var mine: Set<String>

    static let empty = ReactionSummary(counts: [:], mine: [])
}

/// One person's reaction, for the "who reacted" popover.
struct ReactionActor: Sendable, Hashable, Identifiable {
    var id: String { "\(actor.kind.rawValue):\(actor.id)" }
    var actor: MessageActor
    var timestamp: Date?
}

/// Talk's reaction API. Requires the `reactions` capability and attendee permission 256.
actor ReactionService {
    private let client: OCSClient
    /// Used to work out which reactions are the current user's.
    private let currentUserID: String

    init(client: OCSClient, currentUserID: String) {
        self.client = client
        self.currentUserID = currentUserID
    }

    func add(_ emoji: String, token: String, messageID: Int) async throws(TalkError) -> ReactionSummary {
        try await mutate(.post, emoji: emoji, token: token, messageID: messageID)
    }

    func remove(_ emoji: String, token: String, messageID: Int) async throws(TalkError) -> ReactionSummary {
        try await mutate(.delete, emoji: emoji, token: token, messageID: messageID)
    }

    func reactions(token: String, messageID: Int) async throws(TalkError) -> ReactionSummary {
        let response = try await client.send(
            OCSRequest.get(Endpoint.reaction(token, messageID)),
            as: [String: [ReactionActorDTO]].self
        )
        return summary(from: response.value)
    }

    /// Who reacted with what. The same endpoint as ``reactions(token:messageID:)``, kept
    /// separate because the UI that wants names is not the UI that wants counts.
    func reactionDetail(token: String, messageID: Int) async throws(TalkError) -> [String: [ReactionActor]] {
        let response = try await client.send(
            OCSRequest.get(Endpoint.reaction(token, messageID)),
            as: [String: [ReactionActorDTO]].self
        )
        var detail: [String: [ReactionActor]] = [:]
        for (emoji, actors) in response.value ?? [:] where !actors.isEmpty {
            detail[emoji] = actors.map { dto in
                ReactionActor(
                    actor: MessageActor(type: dto.actorType, id: dto.actorId, displayName: dto.actorDisplayName),
                    timestamp: dto.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }
        return detail
    }

    private func mutate(
        _ method: HTTPMethod,
        emoji: String,
        token: String,
        messageID: Int
    ) async throws(TalkError) -> ReactionSummary {
        let form = ["reaction": emoji]
        let path = Endpoint.reaction(token, messageID)
        let request = method == .post ? OCSRequest.post(path, form: form) : OCSRequest.delete(path, form: form)
        // All three reaction endpoints answer with the message's complete reaction map,
        // so the result can be folded straight back into the cache.
        let response = try await client.send(request, as: [String: [ReactionActorDTO]].self)
        return summary(from: response.value)
    }

    private func summary(from map: [String: [ReactionActorDTO]]?) -> ReactionSummary {
        guard let map else { return .empty }
        var counts: [String: Int] = [:]
        var mine: Set<String> = []
        for (emoji, actors) in map where !actors.isEmpty {
            counts[emoji] = actors.count
            if actors.contains(where: { $0.actorType == "users" && $0.actorId == currentUserID }) {
                mine.insert(emoji)
            }
        }
        return ReactionSummary(counts: counts, mine: mine)
    }
}

struct ReactionActorDTO: Decodable, Sendable {
    let actorType: String
    let actorId: String
    let actorDisplayName: String?
    let timestamp: Int?
}
