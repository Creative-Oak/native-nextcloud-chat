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

@Suite("Pinned messages")
struct PinServiceTests {
    @Test("Pins come from the shared items listing, keyed by id, newest pin first")
    func list() async throws {
        let json = """
        {
          "10": {"id":10,"token":"tok","actorType":"users","actorId":"bob","actorDisplayName":"Bob","timestamp":1757000000,
                 "message":"Older message, pinned later","messageParameters":[],"reactions":[],
                 "metaData":{"pinnedActorType":"users","pinnedActorId":"carol","pinnedActorDisplayName":"Carol",
                             "pinnedAt":1757700000,"pinnedUntil":1757786400}},
          "20": {"id":20,"token":"tok","actorType":"users","actorId":"dan","actorDisplayName":"Dan","timestamp":1757100000,
                 "message":"Pinned first","messageParameters":[],"reactions":[],
                 "metaData":{"pinnedActorType":"users","pinnedActorId":"carol","pinnedAt":1757600000}}
        }
        """
        let transport = StubTransport(json: ocsEnvelope(json))
        let pins = try await PinService(client: try client(transport)).pinnedMessages(token: "tok")

        let request = try #require(transport.lastRequest)
        #expect(request.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/share")
        #expect(request.url.query?.contains("objectType=pinned") == true)
        #expect(pins.map(\.id) == [10, 20])
        #expect(pins[0].pinnedBy.displayName == "Carol")
        #expect(pins[0].pinnedUntil == Date(timeIntervalSince1970: 1_757_786_400))
        #expect(pins[1].pinnedUntil == nil)
        #expect(pins[0].isActive(at: Date(timeIntervalSince1970: 1_757_700_001)))
        #expect(!pins[0].isActive(at: Date(timeIntervalSince1970: 1_757_786_401)))
    }

    @Test("Pinning sends pinUntil only when the pin expires; unpin and hide are DELETEs")
    func pinUnpinHide() async throws {
        let transport = StubTransport(json: ocsEnvelope("null"))
        let service = PinService(client: try client(transport))

        try await service.pin(token: "tok", messageID: 7, until: Date(timeIntervalSince1970: 1_757_786_400))
        #expect(transport.lastRequest?.method == .post)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/7/pin")
        #expect(String(decoding: transport.lastRequest?.body ?? Data(), as: UTF8.self) == "pinUntil=1757786400")

        try await service.pin(token: "tok", messageID: 7, until: nil)
        #expect((transport.lastRequest?.body ?? Data()).isEmpty)

        try await service.unpin(token: "tok", messageID: 7)
        #expect(transport.lastRequest?.method == .delete)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/7/pin")

        try await service.hideForMe(token: "tok", messageID: 7)
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/spreed/api/v1/chat/tok/7/pin/self")
        #expect(Endpoint.redacted(Endpoint.pinSelf("tok", 7)) == "/ocs/v2.php/apps/spreed/api/v1/chat/…/…/pin/self")
    }

    @Test("A pin listed by the overview is no longer filed under Other")
    func sharedItemType() {
        #expect(SharedItemType(rawValue: "pinned") == .pinned)
        #expect(!SharedItemType.displayOrder.contains(.pinned))
    }
}
