import Foundation

/// A thread in a conversation, as the thread endpoints describe it.
struct ThreadSummary: Sendable, Hashable, Identifiable {
    var id: Int
    var token: String
    var title: String
    var replies: Int
    var lastActivity: Date
    /// This user's notification level for the thread — ``ThreadNotificationLevel``.
    var notificationLevel: ThreadNotificationLevel
    /// The message that started it, and the newest in it; nil when the server left them out.
    var first: Message?
    var last: Message?
}

/// How much a thread notifies. `default` follows the conversation's own setting.
enum ThreadNotificationLevel: Int, Sendable, CaseIterable, Identifiable {
    case `default` = 0
    case always = 1
    case mentions = 2
    case never = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .default: "Same as Conversation"
        case .always: "All Messages"
        case .mentions: "Mentions Only"
        case .never: "Off"
        }
    }
}

/// Threads beyond reading and posting in them — which there are, renaming, notifications.
/// Cap `threads`. Starting one is sending a message with a title; see ``ChatService``.
actor ThreadService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// The conversation's threads, most recently active first. Talk returns at most 50.
    func recent(token: String, limit: Int = 50) async throws(TalkError) -> [ThreadSummary] {
        let query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        let response = try await client.send(OCSRequest.get(Endpoint.recentThreads(token), query: query), as: [ThreadInfoDTO].self)
        return (response.value ?? []).map { $0.model(token: token) }.sorted { $0.lastActivity > $1.lastActivity }
    }

    func thread(token: String, id: Int) async throws(TalkError) -> ThreadSummary {
        try await client.require(OCSRequest.get(Endpoint.thread(token, id)), as: ThreadInfoDTO.self).value.model(token: token)
    }

    /// Only its author or a moderator may.
    func rename(token: String, id: Int, title: String) async throws(TalkError) -> ThreadSummary {
        let request = OCSRequest.put(Endpoint.thread(token, id), form: ["threadTitle": title])
        return try await client.require(request, as: ThreadInfoDTO.self).value.model(token: token)
    }

    func setNotificationLevel(_ level: ThreadNotificationLevel, token: String, id: Int) async throws(TalkError) -> ThreadSummary {
        let request = OCSRequest.post(Endpoint.threadNotify(token, id), form: ["level": String(level.rawValue)])
        return try await client.require(request, as: ThreadInfoDTO.self).value.model(token: token)
    }
}

/// `ThreadInfo`: the thread, this user's place in it, and its first and last messages.
struct ThreadInfoDTO: Decodable, Sendable {
    struct ThreadDTO: Decodable, Sendable {
        let id: Int
        let roomToken: String?
        let title: String
        let lastActivity: Int
        let numReplies: Int

        private enum CodingKeys: String, CodingKey { case id, roomToken, title, lastActivity, numReplies }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = Lenient.int(container, .id) ?? 0
            roomToken = try? container.decodeIfPresent(String.self, forKey: .roomToken)
            title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
            lastActivity = Lenient.int(container, .lastActivity) ?? 0
            numReplies = Lenient.int(container, .numReplies) ?? 0
        }
    }

    struct AttendeeDTO: Decodable, Sendable {
        let notificationLevel: Int

        private enum CodingKeys: String, CodingKey { case notificationLevel }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notificationLevel = Lenient.int(container, .notificationLevel) ?? 0
        }
    }

    let thread: ThreadDTO
    let attendee: AttendeeDTO?
    let first: MessageDTO?
    let last: MessageDTO?

    private enum CodingKeys: String, CodingKey { case thread, attendee, first, last }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(ThreadDTO.self, forKey: .thread)
        attendee = try? container.decodeIfPresent(AttendeeDTO.self, forKey: .attendee)
        first = try? container.decodeIfPresent(MessageDTO.self, forKey: .first)
        last = try? container.decodeIfPresent(MessageDTO.self, forKey: .last)
    }

    func model(token fallback: String) -> ThreadSummary {
        let token = thread.roomToken ?? fallback
        return ThreadSummary(
            id: thread.id,
            token: token,
            title: thread.title,
            replies: thread.numReplies,
            lastActivity: Date(timeIntervalSince1970: TimeInterval(thread.lastActivity)),
            notificationLevel: ThreadNotificationLevel(rawValue: attendee?.notificationLevel ?? 0) ?? .default,
            first: first?.model(token: token),
            last: last?.model(token: token)
        )
    }
}
