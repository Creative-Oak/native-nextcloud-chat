import Foundation

/// One of the user's groups in the sidebar. Talk calls them tags: the user's own, and two
/// built in — favourites, and everything else — which keep their places at the top and the
/// bottom. Cap `conversation-tags`.
struct ConversationTag: Sendable, Hashable, Identifiable, Codable {
    enum Kind: String, Sendable, Codable {
        case custom, favorites, other
    }

    let id: String
    var name: String
    var sortOrder: Int
    /// Folded in the sidebar — kept on the server, so it's folded everywhere.
    var isCollapsed: Bool
    var kind: Kind
}

/// The user's sidebar groups: making, renaming, ordering, folding and deleting them, and
/// putting conversations in them. Cap `conversation-tags`.
actor ConversationTagService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// In the order they're shown.
    func tags() async throws(TalkError) -> [ConversationTag] {
        Self.ordered(try await client.send(OCSRequest.get(Endpoint.tags), as: [TagDTO].self).value ?? [])
    }

    func create(named name: String) async throws(TalkError) -> ConversationTag {
        try await client.require(OCSRequest.post(Endpoint.tags, form: ["name": name]), as: TagDTO.self).value.model
    }

    func rename(_ id: String, to name: String) async throws(TalkError) -> ConversationTag {
        try await client.require(OCSRequest.put(Endpoint.tag(id), form: ["name": name]), as: TagDTO.self).value.model
    }

    func delete(_ id: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.tag(id)), as: EmptyResponse.self)
    }

    /// All of them, in their new order.
    func reorder(_ ids: [String]) async throws(TalkError) -> [ConversationTag] {
        let request = OCSRequest.json(.put, Endpoint.tags + "/reorder", body: ["orderedIds": ids])
        return Self.ordered(try await client.send(request, as: [TagDTO].self).value ?? [])
    }

    func setCollapsed(_ collapsed: Bool, id: String) async throws(TalkError) -> ConversationTag {
        let request = OCSRequest.put(Endpoint.tag(id) + "/collapsed", form: ["collapsed": collapsed ? "1" : "0"])
        return try await client.require(request, as: TagDTO.self).value.model
    }

    /// Puts `token` in exactly these tags — none takes it out of all of them.
    func assign(_ tagIDs: [String], to token: String) async throws(TalkError) -> Conversation {
        let request = OCSRequest.json(.post, Endpoint.conversationTags(token), body: ["tagIds": tagIDs])
        return try await client.require(request, as: ConversationDTO.self).value.model()
    }

    private static func ordered(_ dtos: [TagDTO]) -> [ConversationTag] {
        dtos.map(\.model).sorted { $0.sortOrder < $1.sortOrder }
    }
}

private struct TagDTO: Decodable, Sendable {
    let id: String
    let name: String
    let sortOrder: Int
    let collapsed: Bool
    let type: String

    private enum CodingKeys: String, CodingKey { case id, name, sortOrder, collapsed, type }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        sortOrder = (try? container.decode(Int.self, forKey: .sortOrder)) ?? 0
        collapsed = (try? container.decode(Bool.self, forKey: .collapsed)) ?? false
        type = (try? container.decode(String.self, forKey: .type)) ?? "custom"
    }

    var model: ConversationTag {
        ConversationTag(id: id, name: name, sortOrder: sortOrder, isCollapsed: collapsed, kind: ConversationTag.Kind(rawValue: type) ?? .custom)
    }
}
