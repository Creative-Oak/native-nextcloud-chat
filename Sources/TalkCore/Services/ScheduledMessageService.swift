import Foundation

/// A message waiting on the server to be sent later. Only its author sees it.
struct ScheduledMessage: Sendable, Hashable, Identifiable {
    /// A Snowflake id, sent as a string — too large to trust to a JSON number.
    let id: String
    var text: String
    var sendAt: Date
    var isSilent: Bool
    /// The message it answers, if it is a reply.
    var parent: ParentMessage?
    /// Set only when sending it failed: the time it should have gone out.
    var failedSendAt: Date?

    var hasFailed: Bool { failedSendAt != nil }
}

/// Scheduled messages. Cap `scheduled-messages`. The server sends them itself, at their time,
/// whether or not any client is running.
actor ScheduledMessageService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// This user's scheduled messages in the conversation, soonest first.
    func scheduled(token: String) async throws(TalkError) -> [ScheduledMessage] {
        let response = try await client.send(OCSRequest.get(Endpoint.schedule(token)), as: [ScheduledMessageDTO].self)
        return (response.value ?? []).map { $0.model(token: token) }.sorted { $0.sendAt < $1.sendAt }
    }

    func schedule(token: String, text: String, sendAt: Date, replyTo: Int? = nil, silent: Bool = false, threadID: Int? = nil, threadTitle: String? = nil) async throws(TalkError) {
        var form = ["message": text, "sendAt": String(Int(sendAt.timeIntervalSince1970))]
        if let replyTo, replyTo > 0 {
            form["replyTo"] = String(replyTo)
        } else if let threadID {
            form["threadId"] = String(threadID)
        } else if let threadTitle, !threadTitle.isEmpty {
            form["threadTitle"] = threadTitle
        }
        if silent { form["silent"] = "true" }
        _ = try await client.send(OCSRequest.post(Endpoint.schedule(token), form: form), as: EmptyResponse.self)
    }

    /// Changes the words or the time — both are always sent, as the endpoint requires.
    func update(token: String, id: String, text: String, sendAt: Date, silent: Bool = false) async throws(TalkError) {
        var form = ["message": text, "sendAt": String(Int(sendAt.timeIntervalSince1970))]
        if silent { form["silent"] = "true" }
        _ = try await client.send(OCSRequest.post(Endpoint.schedule(token, id), form: form), as: EmptyResponse.self)
    }

    func delete(token: String, id: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.schedule(token, id)), as: EmptyResponse.self)
    }
}

struct ScheduledMessageDTO: Decodable, Sendable {
    let id: String
    let message: String
    let sendAt: Int
    let silent: Bool
    let parent: ParentMessageDTO?
    let originalSendAt: Int?

    private enum CodingKeys: String, CodingKey {
        case id, message, sendAt, silent, parent, originalSendAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Lenient.string(container, .id) ?? ""
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        sendAt = Lenient.int(container, .sendAt) ?? 0
        silent = Lenient.bool(container, .silent) ?? false
        parent = try? container.decodeIfPresent(ParentMessageDTO.self, forKey: .parent)
        originalSendAt = Lenient.int(container, .originalSendAt)
    }

    func model(token: String) -> ScheduledMessage {
        ScheduledMessage(
            id: id,
            text: message,
            sendAt: Date(timeIntervalSince1970: TimeInterval(sendAt)),
            isSilent: silent,
            parent: parent?.model(),
            failedSendAt: (originalSendAt ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(originalSendAt ?? 0)) : nil
        )
    }
}
