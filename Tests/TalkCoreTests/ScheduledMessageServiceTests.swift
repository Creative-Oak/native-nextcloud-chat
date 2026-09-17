import Foundation
import Testing
@testable import TalkCore

private func client(_ transport: StubTransport) throws -> OCSClient {
    OCSClient(
        server: try ServerAddress.parse("https://cloud.example.com"),
        credentials: Credentials(loginName: "alice", appPassword: "pw"),
        transport: transport
    )
}

private func form(_ request: HTTPRequest?) -> [String: String] {
    let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        fields[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
    return fields
}

@Suite("Scheduled messages")
struct ScheduledMessageServiceTests {
    @Test("The list decodes, soonest first, with a reply's parent and a failed send")
    func list() async throws {
        let json = """
        [
          {"id":"719456789012345678","actorId":"alice","actorType":"users","threadId":0,"message":"Later",
           "messageType":"comment","createdAt":1757700000,"sendAt":1757900000,"silent":false},
          {"id":"719456789012345679","actorId":"alice","actorType":"users","threadId":0,"message":"Sooner",
           "messageType":"comment","createdAt":1757700000,"sendAt":1757800000,"silent":true,"originalSendAt":1757790000,
           "parent":{"id":41,"actorType":"users","actorId":"bob","actorDisplayName":"Bob","message":"Question?","messageParameters":[]}}
        ]
        """
        let transport = StubTransport(json: ocsEnvelope(json))
        let items = try await ScheduledMessageService(client: try client(transport)).scheduled(token: "tok")

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/schedule")
        #expect(items.map(\.text) == ["Sooner", "Later"])
        #expect(items[0].id == "719456789012345679")
        #expect(items[0].isSilent)
        #expect(items[0].hasFailed)
        #expect(items[0].parent?.messageID == 41)
        #expect(!items[1].hasFailed)
    }

    @Test("Scheduling, changing and deleting send what the endpoints ask for")
    func writes() async throws {
        let transport = StubTransport(json: ocsEnvelope("{}"), status: 201)
        let service = ScheduledMessageService(client: try client(transport))
        let at = Date(timeIntervalSince1970: 1_757_800_000)

        try await service.schedule(token: "tok", text: "Good morning", sendAt: at, replyTo: 41)
        #expect(transport.lastRequest?.method == .post)
        #expect(form(transport.lastRequest) == ["message": "Good morning", "sendAt": "1757800000", "replyTo": "41"])

        try await service.update(token: "tok", id: "719456789012345678", text: "Good morning!", sendAt: at)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/schedule/719456789012345678")
        #expect(form(transport.lastRequest)["message"] == "Good morning!")

        try await service.delete(token: "tok", id: "719456789012345678")
        #expect(transport.lastRequest?.method == .delete)
    }
}
