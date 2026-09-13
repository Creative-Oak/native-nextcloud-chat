import Foundation

/// One page of chat messages plus the cursors the protocol hands back in headers.
struct ChatBatch: Sendable {
    /// Always oldest → newest, whichever direction the request went.
    var messages: [Message]
    /// `X-Chat-Last-Given` — the cursor for the next page in the same direction.
    var lastGivenID: Int?
    /// `X-Chat-Last-Common-Read` — how far everyone else has read.
    var lastCommonReadID: Int?
    /// True when the server returned a full page, so more history probably exists.
    var mayHaveMore: Bool
    /// 304: the long poll timed out with nothing new. Normal.
    var isUnchanged: Bool

    static let unchanged = ChatBatch(messages: [], lastGivenID: nil, lastCommonReadID: nil, mayHaveMore: false, isUnchanged: true)
}

/// The Talk chat API, v1. See docs/NEXTCLOUD_API.md § 5.
actor ChatService {
    private let client: OCSClient

    /// Talk's documented ceilings.
    static let maxLimit = 200
    static let maxPollTimeout = 60

    init(client: OCSClient) {
        self.client = client
    }

    // MARK: - Reading

    /// Reads backwards through history. Never sets the read marker: downloading a message
    /// is not the same as the user seeing it.
    func history(
        token: String,
        lastKnownMessageID: Int? = nil,
        limit: Int = 100,
        includeLastKnown: Bool = false
    ) async throws(TalkError) -> ChatBatch {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "lookIntoFuture", value: "0"),
            URLQueryItem(name: "limit", value: String(min(limit, Self.maxLimit))),
            URLQueryItem(name: "setReadMarker", value: "0"),
            URLQueryItem(name: "markNotificationsAsRead", value: "0"),
            URLQueryItem(name: "noStatusUpdate", value: "1"),
            URLQueryItem(name: "includeLastKnown", value: includeLastKnown ? "1" : "0")
        ]
        if let lastKnownMessageID, lastKnownMessageID > 0 {
            query.append(URLQueryItem(name: "lastKnownMessageId", value: String(lastKnownMessageID)))
        }
        return try await fetch(token: token, query: query, limit: limit, timeout: 30)
    }

    /// Long-polls for new messages.
    ///
    /// - Parameter setReadMarker: only ever true when the conversation is genuinely on
    ///   screen in an active window. See ``ReadStateController``.
    func poll(
        token: String,
        lastKnownMessageID: Int,
        timeout: Int = 30,
        setReadMarker: Bool = false,
        markNotificationsAsRead: Bool = false,
        lastCommonReadID: Int? = nil,
        limit: Int = 100
    ) async throws(TalkError) -> ChatBatch {
        let timeout = min(max(timeout, 1), Self.maxPollTimeout)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "lookIntoFuture", value: "1"),
            URLQueryItem(name: "limit", value: String(min(limit, Self.maxLimit))),
            URLQueryItem(name: "timeout", value: String(timeout)),
            URLQueryItem(name: "lastKnownMessageId", value: String(lastKnownMessageID)),
            URLQueryItem(name: "setReadMarker", value: setReadMarker ? "1" : "0"),
            URLQueryItem(name: "markNotificationsAsRead", value: markNotificationsAsRead ? "1" : "0"),
            URLQueryItem(name: "noStatusUpdate", value: "1"),
            URLQueryItem(name: "includeLastKnown", value: "0")
        ]
        if let lastCommonReadID {
            query.append(URLQueryItem(name: "lastCommonReadId", value: String(lastCommonReadID)))
        }
        // The socket must outlive the server's own timeout, with headroom.
        return try await fetch(token: token, query: query, limit: limit, timeout: TimeInterval(timeout) + 30)
    }

    /// Messages either side of a specific message — used to jump to a reply's parent.
    /// Requires `chat-get-context`.
    func context(token: String, messageID: Int, limit: Int = 50) async throws(TalkError) -> ChatBatch {
        let query = [URLQueryItem(name: "limit", value: String(min(limit, 100)))]
        let response = try await client.send(
            OCSRequest.get(Endpoint.chatContext(token, messageID), query: query),
            as: [MessageDTO].self
        )
        return batch(from: response, token: token, limit: limit)
    }

    private func fetch(
        token: String,
        query: [URLQueryItem],
        limit: Int,
        timeout: TimeInterval
    ) async throws(TalkError) -> ChatBatch {
        var request = OCSRequest.get(Endpoint.chat(token), query: query)
        request.timeout = timeout
        let response = try await client.send(request, as: [MessageDTO].self)
        if response.status == 304 {
            return ChatBatch(
                messages: [],
                lastGivenID: response.headers.chatLastGiven,
                lastCommonReadID: response.headers.chatLastCommonRead,
                mayHaveMore: false,
                isUnchanged: true
            )
        }
        return batch(from: response, token: token, limit: limit)
    }

    private func batch(from response: OCSResponse<[MessageDTO]?>, token: String, limit: Int) -> ChatBatch {
        let raw = response.value ?? []
        // History comes back newest-first and future oldest-first; the rest of the app only
        // ever wants ascending order, so normalize once, here.
        let messages = raw.map { $0.model(token: token) }.sorted { $0.messageID < $1.messageID }
        return ChatBatch(
            messages: messages,
            lastGivenID: response.headers.chatLastGiven,
            lastCommonReadID: response.headers.chatLastCommonRead,
            mayHaveMore: raw.count >= limit,
            isUnchanged: false
        )
    }

    // MARK: - Writing

    /// - Parameter referenceID: opaque id used to match the server's echo with the
    ///   optimistic row we already put on screen. Requires `chat-reference-id`.
    func send(
        token: String,
        message: String,
        replyTo: Int? = nil,
        referenceID: String? = nil,
        silent: Bool = false
    ) async throws(TalkError) -> Message {
        var form = ["message": message]
        if let replyTo, replyTo > 0 { form["replyTo"] = String(replyTo) }
        if let referenceID { form["referenceId"] = referenceID }
        if silent { form["silent"] = "true" }

        let response = try await client.require(OCSRequest.post(Endpoint.chat(token), form: form), as: MessageDTO.self)
        return response.value.model(token: token)
    }

    func edit(token: String, messageID: Int, message: String) async throws(TalkError) -> Message {
        let response = try await client.require(
            OCSRequest.put(Endpoint.chatMessage(token, messageID), form: ["message": message]),
            as: MessageDTO.self
        )
        return response.value.model(token: token)
    }

    /// Deleting returns the **replacement** message (a `comment_deleted` tombstone), so the
    /// row is overwritten rather than removed — which is also what the server will send
    /// every other client.
    func delete(token: String, messageID: Int) async throws(TalkError) -> Message {
        let response = try await client.require(
            OCSRequest.delete(Endpoint.chatMessage(token, messageID)),
            as: MessageDTO.self
        )
        return response.value.model(token: token)
    }

    // MARK: - Read state

    func markRead(token: String, lastReadMessageID: Int?) async throws(TalkError) {
        var form: [String: String] = [:]
        if let lastReadMessageID { form["lastReadMessage"] = String(lastReadMessageID) }
        _ = try await client.send(OCSRequest.post(Endpoint.chatReadMarker(token), form: form), as: ConversationDTO.self)
    }

    /// Requires `chat-unread`.
    func markUnread(token: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.chatReadMarker(token)), as: ConversationDTO.self)
    }
}
