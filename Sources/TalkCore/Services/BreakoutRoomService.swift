import Foundation

/// Breakout rooms: a group conversation split into smaller ones for a while, and gathered
/// back. Moderators set them up, start and stop them, and message all of them at once; the
/// others go to the room they're given — or, in the free mode, pick one — and can ask for a
/// moderator's help from there. Cap `breakout-rooms-v1`.
///
/// Rooms are conversations of their own, with `objectType` `room` and the host's token as
/// their `objectId`. While stopped they have their lobby up, so nobody but moderators gets in.
actor BreakoutRoomService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// Makes `amount` rooms (1 to 20) under `token`. `assignments` — attendee id to room, from
    /// 0 — only counts in the manual mode.
    func setUp(token: String, mode: BreakoutRoomMode, amount: Int, assignments: [Int: Int] = [:]) async throws(TalkError) -> [Conversation] {
        var form = ["mode": String(mode.rawValue), "amount": String(min(max(amount, 1), 20))]
        if mode == .manual { form["attendeeMap"] = Self.attendeeMap(assignments) }
        return try await conversations(OCSRequest.post(Endpoint.breakoutRooms(token), form: form))
    }

    /// Deletes every room, and the setup with them.
    func remove(token: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.delete(Endpoint.breakoutRooms(token)), as: EmptyResponse.self)
    }

    /// Opens the rooms; the server moves everyone in the main conversation into theirs.
    func start(token: String) async throws(TalkError) -> [Conversation] {
        try await conversations(OCSRequest.post(Endpoint.breakoutRooms(token) + "/rooms"))
    }

    /// Closes the rooms; the server moves everyone back.
    func stop(token: String) async throws(TalkError) -> [Conversation] {
        try await conversations(OCSRequest.delete(Endpoint.breakoutRooms(token) + "/rooms"))
    }

    /// Posts `message` in every room, as this moderator.
    func broadcast(_ message: String, token: String) async throws(TalkError) {
        _ = try await client.send(OCSRequest.post(Endpoint.breakoutRooms(token) + "/broadcast", form: ["message": message]), as: EmptyResponse.self)
    }

    /// Puts people in other rooms — the manual mode.
    func reassign(token: String, assignments: [Int: Int]) async throws(TalkError) -> [Conversation] {
        try await conversations(OCSRequest.post(Endpoint.breakoutRooms(token) + "/attendees", form: ["attendeeMap": Self.attendeeMap(assignments)]))
    }

    /// From inside a breakout room: a moderator is wanted. `false` takes it back.
    func askForHelp(_ asking: Bool, roomToken: String) async throws(TalkError) {
        let path = Endpoint.breakoutRooms(roomToken) + "/request-assistance"
        _ = try await client.send(asking ? OCSRequest.post(path) : OCSRequest.delete(path), as: EmptyResponse.self)
    }

    /// The free mode: moves this user to `target`, one of `token`'s rooms.
    func switchTo(_ target: String, token: String) async throws(TalkError) -> Conversation {
        try await client.require(OCSRequest.post(Endpoint.breakoutRooms(token) + "/switch", form: ["target": target]), as: ConversationDTO.self).value.model()
    }

    /// The rooms under `token`: all of them for moderators and in the free mode; otherwise
    /// the one this user is in, and only while they're running.
    func rooms(token: String) async throws(TalkError) -> [Conversation] {
        try await conversations(OCSRequest.get(Endpoint.breakoutRoomList(token)))
            .filter(\.isBreakoutRoom)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func conversations(_ request: OCSRequest) async throws(TalkError) -> [Conversation] {
        (try await client.send(request, as: [ConversationDTO].self).value ?? []).map { $0.model() }
    }

    /// `{"12": 0, "15": 1}` — attendee id to room number, as JSON in a form field.
    static func attendeeMap(_ assignments: [Int: Int]) -> String {
        let object = Dictionary(uniqueKeysWithValues: assignments.map { (String($0.key), $0.value) })
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
