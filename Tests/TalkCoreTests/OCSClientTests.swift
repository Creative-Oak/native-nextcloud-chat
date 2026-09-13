import Foundation
import Testing
@testable import TalkCore

private struct Room: Decodable, Sendable, Equatable {
    let token: String
    let displayName: String
}

@Suite("OCS envelope and client")
struct OCSClientTests {
    private func client(_ transport: StubTransport) throws -> OCSClient {
        OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "app-pw"),
            transport: transport
        )
    }

    @Test("Decodes a success envelope")
    func decodesSuccess() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"token":"abc","displayName":"Design"}"#))
        let response = try await client(transport).require(OCSRequest.get(Endpoint.rooms), as: Room.self)
        #expect(response.value == Room(token: "abc", displayName: "Design"))
    }

    @Test("Sends the OCS headers every request needs")
    func sendsRequiredHeaders() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        _ = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: [Room].self)

        let request = try #require(transport.lastRequest)
        #expect(request.headers["OCS-APIRequest"] == "true")
        #expect(request.headers["Accept"] == "application/json")
        // Basic base64("alice:app-pw")
        #expect(request.headers["Authorization"] == "Basic YWxpY2U6YXBwLXB3")
        #expect(request.url.absoluteString == "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room")
    }

    @Test("Header lookup is case-insensitive, as HTTP requires")
    func caseInsensitiveHeaders() {
        let headers = HTTPHeaders(["X-Chat-Last-Given": "42", "x-nextcloud-talk-hash": "abc"])
        #expect(headers.chatLastGiven == 42)
        #expect(headers["X-NEXTCLOUD-TALK-HASH"] == "abc")
        #expect(headers.talkHash == "abc")
    }

    @Test("`data: []` where an object was expected decodes as no value, not a failure")
    func tolerantEmptyArray() async throws {
        // Talk does exactly this for a conversation that has no messages yet.
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let response = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: Room.self)
        #expect(response.value == nil)
    }

    @Test("A genuine schema mismatch still fails loudly")
    func realMismatchThrows() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"unexpected":true}"#))
        await #expect(throws: TalkError.self) {
            _ = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: Room.self)
        }
    }

    @Test("304 is a normal outcome, not an error")
    func notModified() async throws {
        let transport = StubTransport(sequence: [.status(304)])
        let response = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: [Room].self)
        #expect(response.value == nil)
        #expect(response.status == 304)
    }

    @Test("HTTP status maps onto a typed error", arguments: [
        (401, TalkError.unauthorized),
        (404, TalkError.notFound),
        (406, TalkError.federationUnsupported),
        (412, TalkError.sessionExpired),
        (413, TalkError.payloadTooLarge),
        (422, TalkError.federationUnreachable)
    ])
    func mapsStatusCodes(_ input: (Int, TalkError)) async throws {
        let transport = StubTransport(sequence: [.json(ocsEnvelope("[]", statuscode: input.0), status: input.0)])
        await #expect(throws: input.1) {
            _ = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: [Room].self)
        }
    }

    @Test("The OCS message is carried into the error, so the UI can show the server's words")
    func carriesOCSMessage() async throws {
        let body = #"{"ocs":{"meta":{"status":"failure","statuscode":403,"message":"Author is not allowed to post"},"data":[]}}"#
        let transport = StubTransport(sequence: [.json(body, status: 403)])
        await #expect(throws: TalkError.forbidden(message: "Author is not allowed to post")) {
            _ = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: [Room].self)
        }
    }

    @Test("429 carries the server's Retry-After into the backoff")
    func rateLimitRetryAfter() async throws {
        let transport = StubTransport(sequence: [
            .json(ocsEnvelope("[]", statuscode: 429), status: 429, headers: ["Retry-After": "30"])
        ])
        await #expect(throws: TalkError.rateLimited(retryAfter: 30)) {
            _ = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: [Room].self)
        }
    }

    @Test("Maintenance mode is recognised from its header")
    func maintenanceMode() async throws {
        let transport = StubTransport(sequence: [
            .status(503, headers: ["X-Nextcloud-Maintenance-Mode": "1"])
        ])
        await #expect(throws: TalkError.maintenanceMode) {
            _ = try await client(transport).send(OCSRequest.get(Endpoint.rooms), as: [Room].self)
        }
    }

    @Test("An unauthenticated client refuses to send rather than leaking an anonymous request")
    func requiresCredentials() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let anonymous = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: nil,
            transport: transport
        )
        await #expect(throws: TalkError.notAuthenticated) {
            _ = try await anonymous.send(OCSRequest.get(Endpoint.rooms), as: [Room].self)
        }
        #expect(transport.requestCount == 0)
    }

    @Test("Form bodies are percent-encoded, including emoji and reserved characters")
    func formEncoding() {
        let encoded = String(decoding: OCSClient.formEncode(["reaction": "👍", "message": "a b&c=d+e"]), as: UTF8.self)
        #expect(encoded == "message=a%20b%26c%3Dd%2Be&reaction=%F0%9F%91%8D")
    }
}
