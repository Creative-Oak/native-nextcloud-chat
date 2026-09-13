import Foundation
import Testing
@testable import TalkCore

@Suite("Server-side message search")
struct MessageSearchServiceTests {
    private func client(_ transport: StubTransport) throws -> OCSClient {
        OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
    }

    private func query(_ request: HTTPRequest?) -> [String: String] {
        guard let url = request?.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// A realistic `talk-message` page, matching what `MessageSearch` builds: the title is
    /// the "{user} in {conversation}" template already substituted, the subline is the
    /// message cut down around the match, and everything navigable is in `attributes`.
    private let page = ocsEnvelope("""
    {"name":"Messages","isPaginated":true,"cursor":25,
     "entries":[
       {"thumbnailUrl":"https://cloud.example.com/index.php/avatar/bob/512",
        "title":"Bob Bakker in Design","subline":"…the deployment is on Friday",
        "resourceUrl":"https://cloud.example.com/index.php/call/abc123#message_9911",
        "icon":"icon-talk","rounded":true,
        "attributes":{"conversation":"abc123","messageId":"9911","threadId":"9900",
                      "actorType":"users","actorId":"bob","timestamp":"1757700000"}},
       {"thumbnailUrl":"","title":"Guest in Support","subline":"deployment?",
        "resourceUrl":"https://cloud.example.com/index.php/call/def456#message_12",
        "icon":"icon-talk","rounded":true,
        "attributes":{"conversation":"def456","messageId":"12","actorType":"guests",
                      "actorId":"sha1","timestamp":"1757600000"}}]}
    """)

    @Test("Searches the documented provider and decodes what makes a hit navigable")
    func searchesAllConversations() async throws {
        let transport = StubTransport(json: page)
        let service = MessageSearchService(client: try client(transport))

        let result = try await service.searchMessages(term: "deployment")

        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/search/providers/talk-message/search")
        #expect(query(transport.lastRequest)["term"] == "deployment")
        // No conversation filter when searching everywhere — sending an empty one would
        // pin the search to a conversation with an empty token.
        #expect(query(transport.lastRequest)["conversation"] == nil)

        #expect(result.hits.count == 2)
        #expect(result.hasMore)
        #expect(result.cursor == "25")

        let first = result.hits[0]
        #expect(first.token == "abc123")
        #expect(first.messageID == 9911)
        #expect(first.threadID == 9900)
        #expect(first.actorID == "bob")
        #expect(first.title == "Bob Bakker in Design")
        #expect(first.snippet == "…the deployment is on Friday")
        #expect(first.timestamp == Date(timeIntervalSince1970: 1_757_700_000))
        #expect(first.avatarURL?.absoluteString == "https://cloud.example.com/index.php/avatar/bob/512")

        // A guest has no avatar; the field is an empty string rather than being absent.
        #expect(result.hits[1].avatarURL == nil)
        #expect(result.hits[1].threadID == nil)
    }

    @Test("Restricting to one conversation sends Talk's own filter name")
    func searchesOneConversation() async throws {
        let transport = StubTransport(json: page)
        let service = MessageSearchService(client: try client(transport))

        _ = try await service.searchMessages(term: "deployment", in: "abc123", cursor: "25", limit: 50)

        let sent = query(transport.lastRequest)
        #expect(sent["conversation"] == "abc123")
        #expect(sent["cursor"] == "25")
        #expect(sent["limit"] == "50")
    }

    @Test("An empty term asks the server nothing")
    func emptyTerm() async throws {
        let transport = StubTransport(json: page)
        let service = MessageSearchService(client: try client(transport))

        let result = try await service.searchMessages(term: "   ")

        #expect(result.hits.isEmpty)
        #expect(transport.requestCount == 0)
    }

    @Test("An entry with nothing to navigate to is dropped rather than shown")
    func dropsUnnavigableEntries() async throws {
        // `attributes` arrives as `[]` — PHP's empty array — which is the shape that would
        // otherwise fail decoding and lose the whole page.
        let body = ocsEnvelope("""
        {"name":"Messages","isPaginated":false,"cursor":null,
         "entries":[
           {"thumbnailUrl":"","title":"Somewhere","subline":"no attributes",
            "resourceUrl":"https://cloud.example.com/","icon":"","rounded":false,"attributes":[]},
           {"thumbnailUrl":"","title":"Also somewhere","subline":"message id of zero",
            "resourceUrl":"https://cloud.example.com/","icon":"","rounded":false,
            "attributes":{"conversation":"abc123","messageId":"0"}}]}
        """)
        let transport = StubTransport(json: body)
        let service = MessageSearchService(client: try client(transport))

        let result = try await service.searchMessages(term: "x")

        #expect(result.hits.isEmpty)
        #expect(result.hasMore == false)
    }

    @Test("Availability is asked of the server, not inferred from a version")
    func availability() async throws {
        let body = ocsEnvelope("""
        [{"id":"files","appId":"files","name":"Files","icon":"","order":5,
          "isExternalProvider":false,"triggers":[],"filters":{"term":"string"},"inAppSearch":false},
         {"id":"talk-message","appId":"spreed","name":"Messages","icon":"","order":-2,
          "isExternalProvider":false,"triggers":[],
          "filters":{"term":"string","since":"datetime","conversation":"string"},"inAppSearch":false}]
        """)
        let transport = StubTransport(json: body)
        let service = MessageSearchService(client: try client(transport))

        #expect(await service.isAvailable())
        #expect(transport.lastRequest?.url.path == "/ocs/v2.php/search/providers")

        // Asked once and remembered: the answer changes when an app is enabled, not
        // between keystrokes.
        #expect(await service.isAvailable())
        #expect(transport.requestCount == 1)
    }

    @Test("A server without the provider reports unavailable instead of failing later")
    func unavailable() async throws {
        let transport = StubTransport(json: ocsEnvelope("[]"))
        let service = MessageSearchService(client: try client(transport))
        #expect(await service.isAvailable() == false)
    }

    @Test("A server that refuses the provider list is treated as not having search")
    func providerListFails() async throws {
        let transport = StubTransport(json: "not json at all", status: 500)
        let service = MessageSearchService(client: try client(transport))
        #expect(await service.isAvailable() == false)
    }
}
