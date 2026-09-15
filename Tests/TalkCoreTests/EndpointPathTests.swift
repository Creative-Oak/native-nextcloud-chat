import Foundation
import Testing
@testable import TalkCore

/// `Endpoint` returns **decoded** paths and `ServerAddress.url(path:)` performs the single
/// percent-encoding step. These pin that convention from both ends: nothing may be encoded
/// twice, and nothing a server can name may change which endpoint a request reaches.
@Suite("Endpoint paths")
struct EndpointPathTests {
    private func server() throws -> ServerAddress {
        try ServerAddress.parse("https://cloud.example.com")
    }

    @Test("An ordinary token and an ordinary file name pass through untouched")
    func leavesOrdinaryValuesAlone() throws {
        #expect(Endpoint.chat("a1b2c3d4") == "/ocs/v2.php/apps/spreed/api/v1/chat/a1b2c3d4")
        #expect(Endpoint.chatReadMarker("a1b2c3d4") == "/ocs/v2.php/apps/spreed/api/v1/chat/a1b2c3d4/read")
        #expect(Endpoint.webDAV(userID: "alice", path: "/Talk/report.pdf")
            == "/remote.php/dav/files/alice/Talk/report.pdf")
        let rooms = try server().url(path: Endpoint.rooms)
        #expect(rooms.absoluteString == "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room")
    }

    /// The double-encoding bug: `webDAV` used to percent-encode before `URLComponents`
    /// encoded again, so a space arrived as `%2520` and `café.pdf` as `caf%25C3%25A9.pdf`.
    @Test("A file name with a space or an accent is encoded exactly once")
    func encodesOnce() throws {
        let url = try server().url(path: Endpoint.webDAV(userID: "alice", path: "/Talk/café rapport.pdf"))
        #expect(url.absoluteString
            == "https://cloud.example.com/remote.php/dav/files/alice/Talk/caf%C3%A9%20rapport.pdf")

        let avatar = try server().url(path: Endpoint.userAvatar("alice smith", size: 64))
        #expect(avatar.absoluteString == "https://cloud.example.com/index.php/avatar/alice%20smith/64")
    }

    /// The whole no-injection story rests on `URLComponents` escaping a literal `%`. If a
    /// Foundation release ever stopped doing that, `%2F` would reach the server as a slash —
    /// so the assumption is pinned here rather than left to be discovered.
    @Test("A literal percent sign is escaped, not taken as the start of an escape")
    func escapesPercent() throws {
        let url = try server().url(path: Endpoint.webDAV(userID: "alice", path: "/Talk/50% off.pdf"))
        #expect(url.absoluteString
            == "https://cloud.example.com/remote.php/dav/files/alice/Talk/50%25%20off.pdf")

        let traversal = try server().url(path: Endpoint.webDAV(userID: "alice", path: "/Talk/a%2F..%2F..%2Fb"))
        #expect(traversal.absoluteString.contains("%252F"))
    }

    @Test("A token cannot climb out of its endpoint or add one of its own", arguments: [
        "../../../../index.php/apps/files",
        "..",
        ".",
        "",
        "tok/read",
        "tok?setReadMarker=1",
        "tok#fragment",
        "..\\..\\windows"
    ])
    func tokensStayInOneSegment(_ token: String) throws {
        let url = try server().url(path: Endpoint.chat(token))
        #expect(url.path.hasPrefix("/ocs/v2.php/apps/spreed/api/v1/chat/"))
        // Eight segments: the six of the API prefix, `chat`, and exactly one token.
        #expect(url.path.split(separator: "/", omittingEmptySubsequences: true).count == 8)
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(url.path.contains("/../") == false)
        #expect(url.path.hasSuffix("/..") == false)
    }

    @Test("The same holds for the paths a message id or a provider id lands in")
    func otherInterpolatedValues() throws {
        let reaction = try server().url(path: Endpoint.reaction("../../room", 7))
        #expect(reaction.path == "/ocs/v2.php/apps/spreed/api/v1/reaction/.._.._room/7")

        let provider = try server().url(path: Endpoint.searchProvider("../../../index.php"))
        #expect(provider.path == "/ocs/v2.php/search/providers/.._.._.._index.php/search")

        let dav = try server().url(path: Endpoint.webDAV(userID: "../../admin", path: "../../../etc/passwd"))
        #expect(dav.path == "/remote.php/dav/files/.._.._admin/_/_/_/etc/passwd")
    }

    @Test("A log-safe path keeps the route and drops the token")
    func redactsIdentifiers() {
        #expect(Endpoint.redacted(Endpoint.chatReadMarker("s3cr3ttok"))
            == "/ocs/v2.php/apps/spreed/api/v1/chat/…/read")
        #expect(Endpoint.redacted(Endpoint.rooms) == "/ocs/v2.php/apps/spreed/api/v4/room")
        #expect(Endpoint.redacted(Endpoint.userAvatar("alice", size: 64)) == "/index.php/avatar/…/…")
        #expect(Endpoint.redacted(Endpoint.capabilities) == "/ocs/v2.php/cloud/capabilities")
    }
}

@Suite("Search hit tokens")
struct SearchHitTokenTests {
    private func hit(conversation: String) throws -> MessageSearchHit? {
        let json = """
        {"thumbnailUrl":"","title":"t","subline":"s","resourceUrl":"","icon":"","rounded":false,
         "attributes":{"conversation":"\(conversation)","messageId":"42"}}
        """
        return try JSONDecoder().decode(UnifiedSearchEntryDTO.self, from: Data(json.utf8)).hit()
    }

    @Test("A well-formed token is kept")
    func keepsRealTokens() throws {
        let plain = try hit(conversation: "a1b2c3d4")
        #expect(plain?.token == "a1b2c3d4")
        let mixed = try hit(conversation: "AbC-123_x")
        #expect(mixed?.token == "AbC-123_x")
    }

    /// `attributes` is free-form and any search provider on the server fills it in, so this
    /// is where a string becomes a token the app then polls and writes read markers into.
    @Test("Anything that isn't shaped like a token is dropped", arguments: [
        "", "../../index.php", "tok/read", "tok?x=1", "tok#f", "tok with space", "tok%2F"
    ])
    func dropsUnusableTokens(_ token: String) throws {
        let dropped = try hit(conversation: token)
        #expect(dropped == nil)
    }
}
