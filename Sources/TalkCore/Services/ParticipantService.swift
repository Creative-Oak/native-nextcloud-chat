import Foundation

/// The participant half of the Talk room API.
actor ParticipantService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    func participants(token: String, includeStatus: Bool = true) async throws(TalkError) -> [Participant] {
        let query = [URLQueryItem(name: "includeStatus", value: includeStatus ? "true" : "false")]
        let response = try await client.send(
            OCSRequest.get(Endpoint.participants(token), query: query),
            as: [ParticipantDTO].self
        )
        return (response.value ?? [])
            .map { $0.model() }
            .sorted(by: Participant.listOrder)
    }

    /// Adds someone. `source` must be one of the values Talk documents:
    /// users, groups, circles, emails, federated_users, phones, teams.
    func add(_ entry: DirectoryEntry, to token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.post(Endpoint.participants(token), form: [
                "newParticipant": entry.identifier,
                "source": entry.source.talkSource
            ]),
            as: EmptyResponse.self
        )
    }

    /// Removes a participant. Note this is `/attendees`, not `/participants` — a different
    /// path than the one used to add.
    func remove(attendeeID: Int, from token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.delete(Endpoint.attendees(token), form: ["attendeeId": String(attendeeID)]),
            as: EmptyResponse.self
        )
    }

    /// Leaves the conversation yourself.
    func leave(token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.delete(Endpoint.participants(token) + "/self"),
            as: EmptyResponse.self
        )
    }
}

/// Nextcloud's own people/group search, used when starting a conversation or inviting
/// someone. This is core Nextcloud, not Talk.
actor DirectoryService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// - Parameters:
    ///   - token: an existing conversation to search within, or `nil` when starting a new
    ///     one. Talk passes `itemType: "call"` with the room token (or `new`) so the server
    ///     can rank and filter sensibly.
    ///   - shareTypes: `0` users, `1` groups, `7` teams/circles — the defaults cover
    ///     everyone you can put in a conversation.
    func search(
        _ term: String,
        inConversation token: String? = nil,
        shareTypes: [Int] = [0, 1, 7],
        limit: Int = 20
    ) async throws(TalkError) -> [DirectoryEntry] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        var query = [
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "itemType", value: "call"),
            URLQueryItem(name: "itemId", value: token ?? "new"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        query += shareTypes.map { URLQueryItem(name: "shareTypes[]", value: String($0)) }

        let response = try await client.send(
            OCSRequest.get(Endpoint.autocomplete, query: query),
            as: [AutocompleteResultDTO].self
        )
        return (response.value ?? []).map { $0.model() }
    }
}
