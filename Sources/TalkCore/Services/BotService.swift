import Foundation

/// A bot installed on the server, as a conversation sees it. Bots answer in the chat — a
/// call summary, a reminder, a poll — once a moderator has turned them on for it.
struct ConversationBot: Sendable, Hashable, Identifiable {
    enum State: Int, Sendable {
        case off = 0
        case on = 1
        /// On, and set up by the administrator: moderators can't turn it off.
        case managed = 2
        /// Its app is switched off on the server.
        case unavailable = 3
    }

    let id: Int
    let name: String
    let description: String
    var state: State

    var isOn: Bool { state == .on || state == .managed }
    /// Whether a moderator can turn it on or off here.
    var isAdjustable: Bool { state == .on || state == .off }
}

/// Turning the server's bots on and off in a conversation. Moderators only. Cap `bots-v1`.
actor BotService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    func bots(token: String) async throws(TalkError) -> [ConversationBot] {
        let response = try await client.send(OCSRequest.get(Endpoint.bots(token)), as: [BotDTO].self)
        return (response.value ?? [])
            .map { ConversationBot(id: $0.id, name: $0.name, description: $0.description ?? "", state: ConversationBot.State(rawValue: $0.state ?? 0) ?? .off) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setEnabled(_ isOn: Bool, botID: Int, token: String) async throws(TalkError) {
        let path = Endpoint.bots(token) + "/\(botID)"
        _ = try await client.send(isOn ? OCSRequest.post(path) : OCSRequest.delete(path), as: EmptyResponse.self)
    }
}

private struct BotDTO: Decodable, Sendable {
    let id: Int
    let name: String
    let description: String?
    let state: Int?
}
