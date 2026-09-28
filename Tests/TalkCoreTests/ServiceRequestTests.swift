import Foundation
import Testing
@testable import TalkCore

/// These tests pin the *wire format* — method, path, query and body — against
/// docs/NEXTCLOUD_API.md. If someone "tidies" a parameter away, this is what notices.
@Suite("Service request shapes")
struct ServiceRequestTests {
    private func client(_ transport: StubTransport) throws -> OCSClient {
        OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
    }

    private func form(_ request: HTTPRequest?) -> [String: String] {
        guard let body = request?.body, let text = String(data: body, encoding: .utf8) else { return [:] }
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).removingPercentEncoding ?? "", String(parts[1]).removingPercentEncoding ?? "")
        })
    }

    private func query(_ request: HTTPRequest?) -> [String: String] {
        guard let components = request.flatMap({ URLComponents(url: $0.url, resolvingAgainstBaseURL: false) }),
              let items = components.queryItems
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private let messageJSON = """
    {"id":42,"token":"tok","actorType":"users","actorId":"alice","actorDisplayName":"Alice",
     "timestamp":1757700000,"message":"hi","messageParameters":[],"systemMessage":"",
     "messageType":"comment","isReplyable":true,"referenceId":"ref-1","reactions":[]}
    """

    // MARK: - Conversations

    @Test("Listing conversations uses the v4 room endpoint and never changes online status")
    func conversationList() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        _ = try await ConversationService(client: client(transport)).conversations(modifiedSince: 1_757_000_000)

        let request = try #require(transport.lastRequest)
        #expect(request.method == .get)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v4/room")
        #expect(query(request) == [
            "noStatusUpdate": "1",
            "includeStatus": "true",
            "modifiedSince": "1757000000"
        ])
    }

    @Test("Favourite uses POST to add and DELETE to remove")
    func favourite() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ConversationService(client: try client(transport))

        try await service.setFavorite(true, token: "tok")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/favorite")

        try await service.setFavorite(false, token: "tok")
        #expect(transport.lastRequest?.method == .delete)
    }

    @Test("Archive uses POST to archive and DELETE to bring back")
    func archive() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ConversationService(client: try client(transport))

        try await service.setArchived(true, token: "tok")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/archive")

        try await service.setArchived(false, token: "tok")
        #expect(transport.lastRequest?.method == .delete)
        #expect(Endpoint.redacted(Endpoint.archive("tok")) == "/ocs/v2.php/apps/spreed/api/v4/room/…/archive")
    }

    @Test("The lobby is set with PUT webinar/lobby, with the opening time only when it's on")
    func lobby() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ConversationService(client: try client(transport))

        try await service.setLobby(true, opensAt: Date(timeIntervalSince1970: 1_800_000_000), token: "tok")
        #expect(transport.lastRequest?.method == .put)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/webinar/lobby")
        #expect(form(transport.lastRequest) == ["state": "1", "timer": "1800000000"])

        try await service.setLobby(true, token: "tok")
        #expect(form(transport.lastRequest) == ["state": "1"])

        try await service.setLobby(false, opensAt: Date(), token: "tok")
        #expect(form(transport.lastRequest) == ["state": "0"])
    }

    @Test("Breakout rooms: set up, start, stop, broadcast, help, switch — each on its path")
    func breakoutRooms() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = BreakoutRoomService(client: try client(transport))
        let base = "/ocs/v2.php/apps/spreed/api/v1/breakout-rooms/tok"

        _ = try await service.setUp(token: "tok", mode: .manual, amount: 3, assignments: [12: 0, 15: 2])
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == base)
        #expect(form(transport.lastRequest) == ["mode": "2", "amount": "3", "attendeeMap": #"{"12":0,"15":2}"#])

        // Out of range is brought into it, and only the manual mode sends a map.
        _ = try await service.setUp(token: "tok", mode: .automatic, amount: 40, assignments: [12: 0])
        #expect(form(transport.lastRequest) == ["mode": "1", "amount": "20"])

        _ = try await service.start(token: "tok")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == base + "/rooms")
        _ = try await service.stop(token: "tok")
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == base + "/rooms")

        try await service.broadcast("Five minutes left", token: "tok")
        #expect(transport.lastRequest?.url.path == base + "/broadcast")
        #expect(form(transport.lastRequest) == ["message": "Five minutes left"])

        try await service.askForHelp(true, roomToken: "room2")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/breakout-rooms/room2/request-assistance")
        try await service.askForHelp(false, roomToken: "room2")
        #expect(transport.lastRequest?.method == .delete)

        try await service.remove(token: "tok")
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == base)

        _ = try await service.rooms(token: "tok")
        #expect(transport.lastRequest?.method == .get)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/breakout-rooms")
    }

    @Test("Bots are listed per conversation and turned on with POST, off with DELETE")
    func bots() async throws {
        let list = #"[{"id":3,"name":"Call summary","description":"Posts a summary","state":1},{"id":1,"name":"Admin bot","state":2},{"id":2,"name":"Away","description":"","state":0},{"id":4,"name":"Gone","state":3}]"#
        let transport = StubTransport(json: ocsEnvelope(list))
        let service = BotService(client: try client(transport))

        let bots = try await service.bots(token: "tok")
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/bot/tok")
        #expect(bots.map(\.name) == ["Admin bot", "Away", "Call summary", "Gone"])
        #expect(bots.map(\.isOn) == [true, false, true, false])
        #expect(bots.map(\.isAdjustable) == [false, true, true, false])

        try await service.setEnabled(true, botID: 2, token: "tok")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/bot/tok/2")
        try await service.setEnabled(false, botID: 2, token: "tok")
        #expect(transport.lastRequest?.method == .delete)
    }

    @Test("Tags: ordered and assigned as JSON lists, the rest as forms")
    func conversationTags() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"[{"id":"2","name":"Other","sortOrder":9,"collapsed":false,"type":"other"},{"id":"11","name":"Work","sortOrder":1,"collapsed":true,"type":"custom"}]"#))
        let service = ConversationTagService(client: try client(transport))

        let tags = try await service.tags()
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/tags")
        #expect(tags.map(\.name) == ["Work", "Other"])
        #expect(tags.first?.isCollapsed == true)
        #expect(tags.last?.kind == .other)

        _ = try await service.reorder(["12", "11"])
        #expect(transport.lastRequest?.method == .put)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/tags/reorder")
        #expect(transport.lastRequest?.headers["Content-Type"] == "application/json")
        #expect(transport.lastRequest?.body.map { String(decoding: $0, as: UTF8.self) } == #"{"orderedIds":["12","11"]}"#)

        _ = try? await service.assign([], to: "tok")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/tags")
        #expect(transport.lastRequest?.body.map { String(decoding: $0, as: UTF8.self) } == #"{"tagIds":[]}"#)

        _ = try? await service.setCollapsed(true, id: "11")
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/tags/11/collapsed")
        #expect(form(transport.lastRequest) == ["collapsed": "1"])

        try await service.delete("11")
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/tags/11")
    }

    @Test("Important and sensitive use POST to set and DELETE to clear")
    func importantAndSensitive() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ConversationService(client: try client(transport))

        try await service.setImportant(true, token: "tok")
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/important")
        try await service.setSensitive(false, token: "tok")
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/sensitive")
    }

    @Test("Notification level posts the documented integer")
    func notificationLevel() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        try await ConversationService(client: client(transport)).setNotificationLevel(.mention, token: "tok")

        let request = try #require(transport.lastRequest)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/notify")
        #expect(form(request) == ["level": "2"])
    }

    @Test("Joining a room can avoid forcing other sessions out")
    func joinWithoutForce() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"tok","type":2}"#))
        let service = ConversationService(client: try client(transport))

        _ = try await service.join(token: "tok", force: false)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/participants/active")
        #expect(form(transport.lastRequest).isEmpty)

        _ = try await service.join(token: "tok", force: true)
        #expect(form(transport.lastRequest) == ["force": "true"])
    }

    // MARK: - Chat

    @Test("History reads backwards and never sets the read marker")
    func historyRequest() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        _ = try await ChatService(client: client(transport)).history(token: "tok", lastKnownMessageID: 500, limit: 50)

        let request = try #require(transport.lastRequest)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok")
        let parameters = query(request)
        #expect(parameters["lookIntoFuture"] == "0")
        #expect(parameters["lastKnownMessageId"] == "500")
        #expect(parameters["limit"] == "50")
        #expect(parameters["setReadMarker"] == "0")
        #expect(parameters["markNotificationsAsRead"] == "0")
        #expect(parameters["includeLastKnown"] == "0")
    }

    @Test("Limits are clamped to what the API documents")
    func clampsLimits() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ChatService(client: try client(transport))

        _ = try await service.history(token: "tok", limit: 5_000)
        #expect(query(transport.lastRequest)["limit"] == "200")      // documented maximum

        _ = try await service.poll(token: "tok", lastKnownMessageID: 1, timeout: 600)
        #expect(query(transport.lastRequest)["timeout"] == "60")     // documented maximum
    }

    @Test("The long poll's socket outlives the server's own timeout")
    func pollTimeoutHeadroom() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        _ = try await ChatService(client: client(transport)).poll(token: "tok", lastKnownMessageID: 1, timeout: 30)

        // 30s server-side wait needs more than 30s of client patience, or every poll
        // "fails" just as the server was about to answer.
        #expect(try #require(transport.lastRequest).timeout > 30)
    }

    @Test("Sending posts message, replyTo and referenceId")
    func sendRequest() async throws {
        let transport = StubTransport(json: ocsEnvelope(messageJSON, statuscode: 201))
        let message = try await ChatService(client: client(transport)).send(
            token: "tok", message: "hello there", replyTo: 41, referenceID: "ref-1"
        )

        let request = try #require(transport.lastRequest)
        #expect(request.method == .post)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok")
        #expect(form(request) == ["message": "hello there", "replyTo": "41", "referenceId": "ref-1"])
        #expect(message.messageID == 42)
    }

    @Test("Into a thread: the thread id goes along, unless the message is a reply")
    func sendIntoThread() async throws {
        let transport = StubTransport(json: ocsEnvelope(messageJSON, statuscode: 201))
        let service = ChatService(client: try client(transport))

        _ = try await service.send(token: "tok", message: "in it", threadID: 7)
        #expect(form(transport.lastRequest) == ["message": "in it", "threadId": "7"])

        _ = try await service.send(token: "tok", message: "answer", replyTo: 9, threadID: 7)
        #expect(form(transport.lastRequest) == ["message": "answer", "replyTo": "9"])

        let historyTransport = StubTransport(json: ocsEnvelope("[]"))
        _ = try await ChatService(client: try client(historyTransport)).history(token: "tok", threadID: 7)
        #expect(query(historyTransport.lastRequest)["threadId"] == "7")
    }

    @Test("Starting a thread sends its title, never with a reply or into another thread")
    func sendStartingThread() async throws {
        let transport = StubTransport(json: ocsEnvelope(messageJSON, statuscode: 201))
        let service = ChatService(client: try client(transport))

        _ = try await service.send(token: "tok", message: "first", threadTitle: "Plans")
        #expect(form(transport.lastRequest) == ["message": "first", "threadTitle": "Plans"])

        _ = try await service.send(token: "tok", message: "answer", replyTo: 9, threadTitle: "Plans")
        #expect(form(transport.lastRequest) == ["message": "answer", "replyTo": "9"])
    }

    @Test("Threads: listed, renamed with PUT, notifications with POST")
    func threadRequests() async throws {
        let info = #"{"thread":{"id":7,"roomToken":"tok","title":"T","lastMessageId":8,"lastActivity":1,"numReplies":1},"attendee":{"notificationLevel":0},"first":null,"last":null}"#

        let list = StubTransport(json: ocsEnvelope("[\(info)]"))
        let threads = try await ThreadService(client: client(list)).recent(token: "tok")
        #expect(threads.map(\.id) == [7])
        #expect(list.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/threads/recent")
        #expect(query(list.lastRequest) == ["limit": "50"])

        let rename = StubTransport(json: ocsEnvelope(info))
        _ = try await ThreadService(client: client(rename)).rename(token: "tok", id: 7, title: "New")
        #expect(rename.lastRequest?.method == .put)
        #expect(rename.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/threads/7")
        #expect(form(rename.lastRequest) == ["threadTitle": "New"])

        let notify = StubTransport(json: ocsEnvelope(info))
        _ = try await ThreadService(client: client(notify)).setNotificationLevel(.never, token: "tok", id: 7)
        #expect(notify.lastRequest?.method == .post)
        #expect(notify.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/threads/7/notify")
        #expect(form(notify.lastRequest) == ["level": "3"])
    }

    @Test("Leaving a call, or ending it for everyone")
    func leaveCall() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = CallService(client: try client(transport))

        try await service.leave(token: "tok")
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/call/tok")
        #expect(form(transport.lastRequest).isEmpty)

        try await service.leave(token: "tok", everyone: true)
        #expect(form(transport.lastRequest) == ["all": "true"])
    }

    @Test("A ringing call asks whether to keep ringing: 200 yes, 201 missed, 404 over")
    func callNotificationState() async throws {
        let ringing = StubTransport(json: ocsEnvelope("[]"))
        #expect(try await CallService(client: client(ringing)).notificationState(token: "tok") == .ringing)
        #expect(ringing.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/call/tok/notification-state")

        let missed = StubTransport(json: ocsEnvelope("[]", statuscode: 201), status: 201)
        #expect(try await CallService(client: client(missed)).notificationState(token: "tok") == .missed)
    }

    @Test("A private reply names the conversation the quoted message is in")
    func sendPrivateReply() async throws {
        let transport = StubTransport(json: ocsEnvelope(messageJSON, statuscode: 201))
        let service = ChatService(client: try client(transport))

        _ = try await service.send(token: "dm", message: "just us", replyTo: 41, replyToToken: "group")
        #expect(form(transport.lastRequest) == ["message": "just us", "replyTo": "41", "replyToToken": "group"])

        // The same conversation is an ordinary reply, and no reply sends no token.
        _ = try await service.send(token: "dm", message: "here", replyTo: 41, replyToToken: "dm")
        #expect(form(transport.lastRequest) == ["message": "here", "replyTo": "41"])
        _ = try await service.send(token: "dm", message: "none", replyToToken: "group")
        #expect(form(transport.lastRequest) == ["message": "none"])
    }

    @Test("A reply to nothing doesn't send replyTo at all")
    func sendWithoutReply() async throws {
        let transport = StubTransport(json: ocsEnvelope(messageJSON, statuscode: 201))
        _ = try await ChatService(client: client(transport)).send(token: "tok", message: "hi")
        #expect(form(transport.lastRequest) == ["message": "hi"])
    }

    @Test("Editing is a PUT to the message, deleting is a DELETE")
    func editAndDelete() async throws {
        let transport = StubTransport(json: ocsEnvelope(messageJSON))
        let service = ChatService(client: try client(transport))

        _ = try await service.edit(token: "tok", messageID: 42, message: "fixed")
        #expect(transport.lastRequest?.method == .put)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/42")
        #expect(form(transport.lastRequest) == ["message": "fixed"])

        _ = try await service.delete(token: "tok", messageID: 42)
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/42")
    }

    @Test("Deleting returns the tombstone that replaces the message")
    func deleteReturnsTombstone() async throws {
        let tombstone = """
        {"id":42,"token":"tok","actorType":"deleted_users","actorId":"deleted_users",
         "timestamp":1757700000,"message":"Message deleted by author","messageParameters":[],
         "systemMessage":"","messageType":"comment_deleted","isReplyable":false,"deleted":true,"reactions":[]}
        """
        let transport = StubTransport(json: ocsEnvelope(tombstone))
        let result = try await ChatService(client: client(transport)).delete(token: "tok", messageID: 42)

        #expect(result.messageID == 42)
        #expect(result.isDeleted)
        #expect(result.kind == .commentDeleted)
    }

    @Test("Read markers go to /read; mark-as-unread is the same path with DELETE")
    func readMarkers() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"tok","type":2}"#))
        let service = ChatService(client: try client(transport))

        try await service.markRead(token: "tok", lastReadMessageID: 99)
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/read")
        #expect(form(transport.lastRequest) == ["lastReadMessage": "99"])

        try await service.markUnread(token: "tok")
        #expect(transport.lastRequest?.method == .delete)
    }

    @Test("History arrives newest-first and is handed on oldest-first")
    func normalizesOrdering() async throws {
        let body = ocsEnvelope("""
        [{"id":3,"token":"tok","actorType":"users","actorId":"a","timestamp":3,"message":"c","messageParameters":[],"messageType":"comment","systemMessage":"","reactions":[]},
         {"id":2,"token":"tok","actorType":"users","actorId":"a","timestamp":2,"message":"b","messageParameters":[],"messageType":"comment","systemMessage":"","reactions":[]},
         {"id":1,"token":"tok","actorType":"users","actorId":"a","timestamp":1,"message":"a","messageParameters":[],"messageType":"comment","systemMessage":"","reactions":[]}]
        """)
        let transport = StubTransport(json: body, headers: ["X-Chat-Last-Given": "1", "X-Chat-Last-Common-Read": "3"])
        let batch = try await ChatService(client: client(transport)).history(token: "tok")

        #expect(batch.messages.map(\.messageID) == [1, 2, 3])
        #expect(batch.lastGivenID == 1)
        #expect(batch.lastCommonReadID == 3)
    }

    // MARK: - Reactions

    @Test("Reacting posts the emoji and reads back the whole map")
    func addReaction() async throws {
        let body = ocsEnvelope("""
        {"👍":[{"actorType":"users","actorId":"alice","actorDisplayName":"Alice","timestamp":1},
               {"actorType":"users","actorId":"bob","actorDisplayName":"Bob","timestamp":2}],
         "🎉":[{"actorType":"users","actorId":"bob","actorDisplayName":"Bob","timestamp":3}]}
        """)
        let transport = StubTransport(json: body, status: 201)
        let service = ReactionService(client: try client(transport), currentUserID: "alice")

        let summary = try await service.add("👍", token: "tok", messageID: 42)

        let request = try #require(transport.lastRequest)
        #expect(request.method == .post)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/reaction/tok/42")
        #expect(form(request) == ["reaction": "👍"])

        #expect(summary.counts == ["👍": 2, "🎉": 1])
        // Only the emoji this account actually used counts as mine.
        #expect(summary.mine == ["👍"])
    }

    @Test("Removing a reaction sends DELETE with the emoji")
    func removeReaction() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ReactionService(client: try client(transport), currentUserID: "alice")

        let summary = try await service.remove("👍", token: "tok", messageID: 42)
        #expect(transport.lastRequest?.method == .delete)
        #expect(form(transport.lastRequest) == ["reaction": "👍"])
        // `[]` for "no reactions left" must not be a decoding failure.
        #expect(summary == .empty)
    }

    @Test("An emoji with no reactors is dropped rather than shown as a zero")
    func dropsEmptyReactionBuckets() async throws {
        let body = ocsEnvelope(#"{"👍":[],"🎉":[{"actorType":"users","actorId":"bob","timestamp":1}]}"#)
        let transport = StubTransport(json: body)
        let summary = try await ReactionService(client: client(transport), currentUserID: "alice")
            .reactions(token: "tok", messageID: 42)

        #expect(summary.counts == ["🎉": 1])
    }
}
