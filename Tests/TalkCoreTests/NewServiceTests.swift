import Foundation
import Testing
@testable import TalkCore

@Suite("Participants, directory, shared items, attachments")
struct NewServiceTests {
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

    // MARK: - Participants

    @Test("Decodes a participant list, including someone with no session")
    func participants() async throws {
        let body = ocsEnvelope("""
        [{"attendeeId":41,"actorType":"users","actorId":"alice","displayName":"Alice Andersen",
          "participantType":1,"permissions":254,"attendeePermissions":0,"lastPing":1757700000,
          "inCall":3,"sessionIds":["abc"],"status":"online","statusMessage":"Focusing","attendeePin":""},
         {"attendeeId":42,"actorType":"users","actorId":"bob","displayName":"Bob Bakker",
          "participantType":3,"permissions":0,"attendeePermissions":0,"lastPing":0,
          "inCall":0,"sessionIds":["0"],"attendeePin":""},
         {"attendeeId":43,"actorType":"guests","actorId":"sha1","displayName":"",
          "participantType":4,"permissions":0,"lastPing":0,"inCall":0,"sessionIds":[],"attendeePin":""}]
        """)
        let transport = StubTransport(json: body)
        let people = try await ParticipantService(client: try client(transport)).participants(token: "tok")

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/participants")
        #expect(people.count == 3)

        // Moderators first, then online, then by name.
        #expect(people[0].actor.id == "alice")
        #expect(people[0].isModerator)
        #expect(people[0].isInCall)
        #expect(people[0].isOnline)
        #expect(people[0].status?.message == "Focusing")

        // "0" is Talk's way of saying "no session"; it must not read as online.
        let bob = try #require(people.first { $0.actor.id == "bob" })
        #expect(bob.isOnline == false)
        #expect(bob.sessionIDs.isEmpty)

        let guest = try #require(people.first { $0.actor.kind == .guests })
        #expect(guest.displayName == "Guest")
    }

    @Test("Adding a participant uses the documented source values")
    func addParticipant() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = ParticipantService(client: try client(transport))

        try await service.add(
            DirectoryEntry(identifier: "design", label: "Design", source: .groups),
            to: "tok"
        )
        #expect(transport.lastRequest?.method == .post)
        #expect(form(transport.lastRequest) == ["newParticipant": "design", "source": "groups"])
    }

    @Test("Removing a participant goes to /attendees, not /participants")
    func removeParticipant() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        try await ParticipantService(client: try client(transport)).remove(attendeeID: 42, from: "tok")

        let request = try #require(transport.lastRequest)
        #expect(request.method == .delete)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v4/room/tok/attendees")
        #expect(form(request) == ["attendeeId": "42"])
    }

    // MARK: - Directory search

    @Test("People search uses core autocomplete and decodes users, groups and teams")
    func directorySearch() async throws {
        let body = ocsEnvelope("""
        [{"id":"bob","label":"Bob Bakker","icon":"icon-user","source":"users","subline":"bob@example.com",
          "shareWithDisplayNameUnique":"bob@example.com","status":{"status":"online","message":"At work","icon":"💼","clearAt":1757720000}},
         {"id":"design","label":"Design","icon":"icon-group","source":"groups","subline":"","shareWithDisplayNameUnique":"","status":""},
         {"id":"team1","label":"Product","icon":"icon-team","source":"teams","subline":"","shareWithDisplayNameUnique":"","status":""}]
        """)
        let transport = StubTransport(json: body)
        let results = try await DirectoryService(client: try client(transport)).search("b", inConversation: nil)

        let request = try #require(transport.lastRequest)
        #expect(request.url.path == "/ocs/v2.php/core/autocomplete/get")
        let query = try #require(request.url.query())
        #expect(query.contains("search=b"))
        #expect(query.contains("itemType=call"))
        #expect(query.contains("itemId=new"))
        #expect(query.contains("shareTypes%5B%5D=0") || query.contains("shareTypes[]=0"))

        #expect(results.count == 3)
        #expect(results[0].label == "Bob Bakker")
        #expect(results[0].source == .users)
        #expect(results[0].status?.message == "At work")
        #expect(results[1].isGroupLike)
        #expect(results[2].source == .teams)
        #expect(results[2].source.talkSource == "teams")
    }

    @Test("An empty status arrives as a string, not an object, and must not break decoding")
    func emptyStatusObject() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"[{"id":"x","label":"X","source":"users","status":""}]"#))
        let results = try await DirectoryService(client: try client(transport)).search("x")
        #expect(results.count == 1)
        #expect(results[0].status == nil)
    }

    @Test("An empty search never hits the network")
    func emptySearch() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        #expect(try await DirectoryService(client: try client(transport)).search("  ").isEmpty)
        #expect(transport.requestCount == 0)
    }

    // MARK: - Conversation creation

    @Test("Creating a one-to-one sends the documented room type and invite")
    func createOneToOne() async throws {
        // 201 on the response as well as in the envelope, the way Nextcloud answers OCS v2 —
        // the HTTP status is what says whether the room was made or merely found.
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"new1","type":1,"name":"bob","displayName":"Bob"}"#, statuscode: 201), status: 201)
        let created = try await ConversationService(client: try client(transport)).create(.oneToOne(with: "bob"))

        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v4/room")
        #expect(form(transport.lastRequest) == ["roomType": "1", "invite": "bob", "source": "users"])
        #expect(created.conversation.token == "new1")
        #expect(created.conversation.isOneToOne)
        #expect(created.existed == false)   // 201: Talk made it
    }

    @Test("Creating a group sends its name, and a public room its password")
    func createGroupAndPublic() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"new2","type":2,"name":"Design"}"#, statuscode: 201))
        let service = ConversationService(client: try client(transport))

        _ = try await service.create(.group(named: "Design", inviting: DirectoryEntry(identifier: "design", label: "Design", source: .groups)))
        #expect(form(transport.lastRequest) == ["roomType": "2", "roomName": "Design", "invite": "design", "source": "groups"])

        _ = try await service.create(.publicRoom(named: "Open questions", password: "hunter2"))
        #expect(form(transport.lastRequest) == ["roomType": "3", "roomName": "Open questions", "password": "hunter2"])
    }

    @Test("A draft sends everyone in one call, as an indexed participants array")
    func createWithParticipants() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"new3","type":2,"name":"Heine & Lea"}"#, statuscode: 201))
        let service = ConversationService(client: try client(transport))

        let draft = try #require(NewConversation.draft(
            recipients: [
                DirectoryEntry(identifier: "heine", label: "Heine", source: .users),
                DirectoryEntry(identifier: "lea", label: "Lea", source: .users),
                DirectoryEntry(identifier: "design", label: "Design", source: .groups)
            ],
            isOpen: false
        ))
        _ = try await service.create(draft)

        let fields = form(transport.lastRequest)
        #expect(fields["roomType"] == "2")
        #expect(fields["roomName"] == "Heine, Lea & Design")
        // One call rather than a create plus an invitation each.
        #expect(fields["participants[users][0]"] == "heine")
        #expect(fields["participants[users][1]"] == "lea")
        #expect(fields["participants[groups][0]"] == "design")
        #expect(fields["invite"] == nil)
    }

    @Test("A one-to-one you already have comes back as one that already existed")
    func createOneToOneThatExists() async throws {
        // 200, not 201: `RoomController::createOneToOneRoom` looks for the room first and
        // hands back the one you have. Telling the two apart is what makes a new message to
        // someone you already talk to land in the conversation you already have.
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"old1","type":1,"name":"bob"}"#), status: 200)
        let created = try await ConversationService(client: try client(transport)).create(.oneToOne(with: "bob"))

        #expect(created.existed)
        #expect(created.conversation.token == "old1")
    }

    // MARK: - Shared items

    @Test("The overview is a map of type to messages")
    func sharedOverview() async throws {
        let body = ocsEnvelope("""
        {"media":[{"id":10,"token":"tok","actorType":"users","actorId":"bob","timestamp":1,"message":"{file}",
                   "messageParameters":{"file":{"type":"file","id":"1","name":"photo.jpg","mimetype":"image/jpeg","preview-available":"yes"}},
                   "systemMessage":"","messageType":"comment","reactions":[]}],
         "file":[{"id":9,"token":"tok","actorType":"users","actorId":"bob","timestamp":1,"message":"{file}",
                  "messageParameters":{"file":{"type":"file","id":"2","name":"budget.xlsx"}},
                  "systemMessage":"","messageType":"comment","reactions":[]}],
         "voice":[]}
        """)
        let transport = StubTransport(json: body)
        let overview = try await SharedItemsService(client: try client(transport)).overview(token: "tok")

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/share/overview")
        #expect(Set(overview.keys) == [.media, .file])   // empty buckets are dropped
        #expect(overview[.media]?.first?.parameters["file"]?.name == "photo.jpg")
        #expect(overview[.media]?.first?.parameters["file"]?.previewAvailable == true)
    }

    @Test("A single type's listing is keyed by message id, not an array, and comes back newest first")
    func sharedItemsByType() async throws {
        let body = ocsEnvelope("""
        {"10":{"id":10,"token":"tok","actorType":"users","actorId":"bob","timestamp":1,"message":"{file}",
               "messageParameters":[],"systemMessage":"","messageType":"comment","reactions":[]},
         "12":{"id":12,"token":"tok","actorType":"users","actorId":"bob","timestamp":2,"message":"{file}",
               "messageParameters":[],"systemMessage":"","messageType":"comment","reactions":[]},
         "11":{"id":11,"token":"tok","actorType":"users","actorId":"bob","timestamp":3,"message":"{file}",
               "messageParameters":[],"systemMessage":"","messageType":"comment","reactions":[]}}
        """)
        let transport = StubTransport(json: body)
        let items = try await SharedItemsService(client: try client(transport)).items(token: "tok", type: .media)

        #expect(items.map(\.messageID) == [12, 11, 10])
        #expect(try #require(transport.lastRequest?.url.query()).contains("objectType=media"))
    }

    // MARK: - Attachments

    @Test("Uploads go to the user's WebDAV path and never silently overwrite")
    func upload() async throws {
        let transport = StubTransport(json: "", status: 201)
        let service = AttachmentService(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            userID: "alice",
            transport: transport,
            client: try client(transport)
        )

        let path = try await service.upload(Data("hello".utf8), fileName: "report.pdf", folder: "/Talk", progress: { _ in })

        let request = try #require(transport.lastRequest)
        #expect(request.method == .put)
        #expect(request.url.path == "/remote.php/dav/files/alice/Talk/report.pdf")
        #expect(request.headers["If-None-Match"] == "*")          // create, never replace
        #expect(request.headers["X-NC-WebDAV-Auto-Mkcol"] == "1") // make /Talk if it's missing
        #expect(request.headers["Authorization"] == "Basic YWxpY2U6cHc=")
        #expect(path == "/Talk/report.pdf")
    }

    @Test("A name clash gets a numbered name rather than clobbering the file")
    func uploadNameClash() async throws {
        let attempts = Counter()
        let transport = StubTransport { _ in
            // The first two names are taken.
            attempts.bump() < 2 ? .status(412) : .status(201)
        }
        let service = AttachmentService(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            userID: "alice",
            transport: transport,
            client: try client(transport)
        )

        let path = try await service.upload(Data("x".utf8), fileName: "report.pdf", folder: "/Talk", progress: { _ in })
        #expect(path == "/Talk/report (3).pdf")
    }

    @Test("Numbered names read the way Finder's do", arguments: [
        (0, "report.pdf"), (1, "report (2).pdf"), (2, "report (3).pdf")
    ])
    func numberedNames(_ input: (Int, String)) {
        #expect(AttachmentService.name("report.pdf", attempt: input.0) == input.1)
    }

    @Test("A file with no extension is still numbered sensibly")
    func numberedNameWithoutExtension() {
        #expect(AttachmentService.name("README", attempt: 1) == "README (2)")
    }

    @Test("Sharing a file into a conversation uses shareType 10 and Talk's metadata")
    func shareIntoConversation() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"), status: 200)
        let service = AttachmentService(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            userID: "alice",
            transport: transport,
            client: try client(transport)
        )

        try await service.share(path: "/Talk/report.pdf", token: "tok", caption: "Here you go", replyTo: 41, referenceID: "ref-1")

        let request = try #require(transport.lastRequest)
        #expect(request.url.path == "/ocs/v2.php/apps/files_sharing/api/v1/shares")
        let fields = form(request)
        #expect(fields["shareType"] == "10")
        #expect(fields["shareWith"] == "tok")
        #expect(fields["path"] == "/Talk/report.pdf")
        #expect(fields["referenceId"] == "ref-1")

        let metadata = try JSONSerialization.jsonObject(with: Data((fields["talkMetaData"] ?? "").utf8)) as? [String: Any]
        #expect(metadata?["messageType"] as? String == "comment")
        #expect(metadata?["caption"] as? String == "Here you go")
        #expect(metadata?["replyTo"] as? Int == 41)
    }

    @Test("Removing a staged file takes it out of the user's Nextcloud too")
    func deleteStagedFile() async throws {
        let transport = StubTransport(json: "", status: 204)
        let service = AttachmentService(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            userID: "alice",
            transport: transport,
            client: try client(transport)
        )

        try await service.delete(path: "/Talk/report.pdf")

        let request = try #require(transport.lastRequest)
        #expect(request.method == .delete)
        #expect(request.url.path == "/remote.php/dav/files/alice/Talk/report.pdf")
    }

    @Test("A staged file that is already gone counts as removed")
    func deleteMissingFileIsNotAnError() async throws {
        let transport = StubTransport(json: "", status: 404)
        let service = AttachmentService(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            userID: "alice",
            transport: transport,
            client: try client(transport)
        )

        // The point of removing it was that it should not be there. It isn't.
        try await service.delete(path: "/Talk/gone.pdf")
    }

    // MARK: - Staging

    @Test("The words go on the first staged file, and the rest arrive bare")
    func captionLandsOnTheFirstTransfer() {
        var transfers = [
            FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/a.png"), byteCount: 1),
            FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/b.png"), byteCount: 1),
            FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/c.png"), byteCount: 1)
        ]

        let committed = FileTransfer.apply(caption: "  look at these  ", replyTo: 7, to: &transfers)

        #expect(transfers[0].caption == "look at these")
        #expect(transfers[1].caption.isEmpty)
        #expect(transfers[2].caption.isEmpty)
        // The reply is the message's, not one file's: all three belong to it.
        #expect(transfers.allSatisfy { $0.replyToMessageID == 7 })
        #expect(committed.count == 3)
    }

    @Test("A file from an already-sent message is left out of the next one")
    func finishedTransfersAreNotRecommitted() {
        var transfers = [
            FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/sent.png"), byteCount: 1),
            FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/staged.png"), byteCount: 1)
        ]
        transfers[0].state = .completed
        transfers[0].caption = "the last thing I said"

        let committed = FileTransfer.apply(caption: "and this", replyTo: nil, to: &transfers)

        // The caption skips past the finished one rather than landing on it — otherwise the
        // new message's words would be stamped onto a message already sent.
        #expect(transfers[0].caption == "the last thing I said")
        #expect(transfers[1].caption == "and this")
        #expect(committed == [transfers[1].id])
    }

    @Test("A staged file rests at nine tenths, and is not finished")
    func stagedTransferState() {
        var transfer = FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/a.png"), byteCount: 10)
        transfer.state = .uploaded
        #expect(transfer.state.isStaged)
        // Not finished: it has not been anywhere near the conversation yet.
        #expect(transfer.state.isFinished == false)
        #expect(transfer.state.fraction == 0.9)
        #expect(FileTransfer.State.sharing.isStaged == false)
    }

    @Test("Transfer progress is monotonic and ends at 1")
    func transferProgress() {
        var transfer = FileTransfer(fileURL: URL(fileURLWithPath: "/tmp/a.png"), byteCount: 10)
        #expect(transfer.state.fraction == 0)
        transfer.state = .uploading(0.5)
        #expect(transfer.state.fraction > 0 && transfer.state.fraction < 0.95)
        transfer.state = .sharing
        #expect(transfer.state.fraction == 0.95)
        transfer.state = .completed
        #expect(transfer.state.fraction == 1)
        #expect(transfer.state.isFinished)
    }
}

/// Counts calls across a `@Sendable` stub closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
