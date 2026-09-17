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

@Suite("Nextcloud notifications")
struct NotificationsServiceTests {
    @Test("Talk's notifications are sorted by what they are about; everything else is other")
    func decodesKinds() async throws {
        let json = """
        [
          {"notification_id":11,"app":"spreed","object_type":"call","object_id":"abc123","subject":"Bob wants to talk with you",
           "message":"","link":"https://cloud.example.com/call/abc123","datetime":"2026-09-17T10:00:00+00:00"},
          {"notification_id":12,"app":"spreed","object_type":"chat","object_id":"abc123/991","subject":"Bob mentioned you",
           "message":"hi @alice","link":"javascript:alert(1)"},
          {"notification_id":13,"app":"spreed","object_type":"reminder","object_id":"abc123/42","subject":"Reminder"},
          {"notification_id":14,"app":"spreed","object_type":"room","object_id":"xyz789","subject":"Carol invited you"},
          {"notification_id":15,"app":"files_sharing","object_type":"share","object_id":"77","subject":"Dan shared a file"}
        ]
        """
        let transport = StubTransport(json: ocsEnvelope(json), headers: ["ETag": "\"e1\""])
        let outcome = try await NotificationsService(client: try client(transport)).notifications(etag: nil)

        guard case .changed(let items, let etag) = outcome else {
            Issue.record("expected a list, got \(outcome)")
            return
        }
        #expect(etag == "\"e1\"")
        #expect(items.map(\.kind) == [
            .call(token: "abc123"), .chat(token: "abc123"), .reminder(token: "abc123"),
            .invitation(token: "xyz789"), .other
        ])
        #expect(items[0].subject == "Bob wants to talk with you")
        #expect(items[0].link?.host() == "cloud.example.com")
        #expect(items[1].link == nil)   // not a web link, so not a link at all
        #expect(items[0].date != nil)
    }

    @Test("The ETag is sent back, and an unchanged list is a 304 that costs nothing")
    func conditional() async throws {
        let transport = StubTransport(json: "", status: 304)
        let outcome = try await NotificationsService(client: try client(transport)).notifications(etag: "\"e1\"")
        #expect(outcome == .unchanged)
        #expect(transport.lastRequest?.headers["If-None-Match"] == "\"e1\"")
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/apps/notifications/api/v2/notifications")
    }

    @Test("No notifications app is remembered as unavailable, not an error")
    func unavailable() async throws {
        let noApp = StubTransport(json: "", status: 204)
        #expect(try await NotificationsService(client: try client(noApp)).notifications(etag: nil) == .unavailable)
        let missing = StubTransport(json: ocsEnvelope("[]", statuscode: 404), status: 404)
        #expect(try await NotificationsService(client: try client(missing)).notifications(etag: nil) == .unavailable)
    }
}
