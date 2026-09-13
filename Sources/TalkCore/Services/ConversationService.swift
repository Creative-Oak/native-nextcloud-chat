import Foundation

struct ConversationListResult: Sendable {
    var conversations: [Conversation]
    /// Echo this back as the next `modifiedSince`; it is the server's clock, not ours.
    var modifiedBefore: Int?
    var talkHash: String?
    /// False for a full refresh, in which case conversations missing from the result have
    /// genuinely gone away and must be deleted locally.
    var isIncremental: Bool
}

/// The Talk conversation (room) API, v4.
actor ConversationService {
    let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// - Parameters:
    ///   - modifiedSince: only conversations active since this timestamp. Cheap, but
    ///     **cannot express removals** — see ``ConversationSyncEngine`` for the policy.
    ///   - includeStatus: user status for one-to-one conversations.
    func conversations(
        modifiedSince: Int? = nil,
        includeStatus: Bool = true
    ) async throws(TalkError) -> ConversationListResult {
        var query: [URLQueryItem] = [
            // Fetching the sidebar must never make the user look "online" to everyone else.
            URLQueryItem(name: "noStatusUpdate", value: "1")
        ]
        if includeStatus { query.append(URLQueryItem(name: "includeStatus", value: "true")) }
        if let modifiedSince, modifiedSince > 0 {
            query.append(URLQueryItem(name: "modifiedSince", value: String(modifiedSince)))
        }

        let response = try await client.send(OCSRequest.get(Endpoint.rooms, query: query), as: [ConversationDTO].self)
        let conversations = (response.value ?? []).map { $0.model() }

        Log.sync.debug("Fetched \(conversations.count) conversations (incremental: \(modifiedSince != nil))")
        return ConversationListResult(
            conversations: conversations,
            modifiedBefore: response.headers.talkModifiedBefore,
            talkHash: response.headers.talkHash,
            isIncremental: modifiedSince != nil
        )
    }

    func conversation(token: String) async throws(TalkError) -> Conversation {
        try await client.require(OCSRequest.get(Endpoint.room(token)), as: ConversationDTO.self).value.model()
    }

    /// Fetches (and, server-side, creates on first use) the Note to Self conversation.
    func noteToSelf() async throws(TalkError) -> Conversation {
        try await client.require(OCSRequest.get(Endpoint.noteToSelf), as: ConversationDTO.self).value.model()
    }

    func setFavorite(_ isFavorite: Bool, token: String) async throws(TalkError) {
        let request = isFavorite
            ? OCSRequest.post(Endpoint.favorite(token))
            : OCSRequest.delete(Endpoint.favorite(token))
        _ = try await client.send(request, as: EmptyResponse.self)
    }

    func setNotificationLevel(_ level: NotificationLevel, token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.post(Endpoint.notify(token), form: ["level": String(level.rawValue)]),
            as: EmptyResponse.self
        )
    }

    // MARK: - Session

    /// Joins the conversation, creating the session the chat endpoints need.
    ///
    /// A 412 from a chat call means this session died and has to be re-established — that
    /// is the whole reason this exists in a chat-only client.
    @discardableResult
    func join(token: String, force: Bool = true) async throws(TalkError) -> Conversation {
        let request = OCSRequest.post(
            Endpoint.activeParticipants(token),
            form: force ? ["force": "true"] : [:]
        )
        return try await client.require(request, as: ConversationDTO.self).value.model()
    }

    func leave(token: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.activeParticipants(token)), as: EmptyResponse.self)
    }

    /// Tells the server whether this client is actively looking at the conversation.
    /// Requires the `session-state` capability; callers check before calling.
    func setSessionState(active: Bool, token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.put(Endpoint.sessionState(token), form: ["state": active ? "1" : "0"]),
            as: EmptyResponse.self
        )
    }
}

// MARK: - Creating and managing conversations

/// What to create. `roomType` values are the documented constants; the optional fields map
/// one-to-one onto the documented `POST /room` body.
struct NewConversation: Sendable, Equatable {
    var type: ConversationType
    var name: String
    /// User, group or team id to invite immediately.
    var invite: String?
    /// The `source` for `invite` — users, groups, teams, circles…
    var source: String?
    var description: String?
    var password: String?

    /// A direct conversation with one person. Talk returns the existing one if there is one.
    static func oneToOne(with userID: String) -> NewConversation {
        NewConversation(type: .oneToOne, name: "", invite: userID, source: "users")
    }

    static func group(named name: String, inviting entry: DirectoryEntry? = nil) -> NewConversation {
        NewConversation(
            type: .group,
            name: name,
            invite: entry?.identifier,
            source: entry?.source.talkSource
        )
    }

    static func publicRoom(named name: String, password: String? = nil) -> NewConversation {
        NewConversation(type: .publicRoom, name: name, password: password)
    }
}

extension ConversationService {
    /// `POST /room`. Returns the created conversation — or the existing one, when asking for
    /// a one-to-one that already exists, which the server answers with 200 rather than 201.
    func create(_ new: NewConversation) async throws(TalkError) -> Conversation {
        var form: [String: String] = ["roomType": String(new.type.rawValue)]
        if !new.name.isEmpty { form["roomName"] = new.name }
        if let invite = new.invite, !invite.isEmpty { form["invite"] = invite }
        if let source = new.source, !source.isEmpty { form["source"] = source }
        if let description = new.description, !description.isEmpty { form["description"] = description }
        if let password = new.password, !password.isEmpty { form["password"] = password }

        return try await client.require(OCSRequest.post(Endpoint.rooms, form: form), as: ConversationDTO.self)
            .value
            .model()
    }

    func rename(token: String, to name: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.put(Endpoint.room(token), form: ["roomName": name]),
            as: ConversationDTO.self
        )
    }

    func setDescription(_ description: String, token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.put(Endpoint.room(token) + "/description", form: ["description": description]),
            as: ConversationDTO.self
        )
    }

    /// `state`: 0 read-write, 1 read-only. Requires the `read-only-rooms` capability.
    func setReadOnly(_ isReadOnly: Bool, token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.put(Endpoint.room(token) + "/read-only", form: ["state": isReadOnly ? "1" : "0"]),
            as: ConversationDTO.self
        )
    }

    /// Seconds until messages disappear; `0` disables it. Requires `message-expiration`.
    func setMessageExpiration(seconds: Int, token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.post(Endpoint.room(token) + "/message-expiration", form: ["seconds": String(seconds)]),
            as: EmptyResponse.self
        )
    }

    /// Sets or clears the conversation password. An empty string removes it.
    func setPassword(_ password: String, token: String) async throws(TalkError) {
        _ = try await client.send(
            OCSRequest.put(Endpoint.room(token) + "/password", form: ["password": password]),
            as: EmptyResponse.self
        )
    }

    /// Opens the conversation to guests with a link, or closes it again.
    func setPublic(_ isPublic: Bool, token: String, password: String? = nil) async throws(TalkError) {
        let path = Endpoint.room(token) + "/public"
        let request = isPublic
            ? OCSRequest.post(path, form: password.map { ["password": $0] } ?? [:])
            : OCSRequest.delete(path)
        _ = try await client.send(request, as: EmptyResponse.self)
    }

    /// Deletes the conversation for everyone. Moderators only, and never for a one-to-one —
    /// the server enforces both, and the UI hides the command via `canDeleteConversation`.
    func delete(token: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.room(token)), as: EmptyResponse.self)
    }
}
