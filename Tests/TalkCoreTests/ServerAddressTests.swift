import Foundation
import Testing
@testable import TalkCore

@Suite("Server address normalization")
struct ServerAddressTests {
    @Test("A bare host becomes an HTTPS URL")
    func bareHost() throws {
        let address = try ServerAddress.parse("cloud.example.com")
        #expect(address.url.absoluteString == "https://cloud.example.com")
    }

    @Test("Trailing slashes and whitespace are trimmed")
    func trailingSlash() throws {
        let address = try ServerAddress.parse("  https://cloud.example.com///  ")
        #expect(address.url.absoluteString == "https://cloud.example.com")
    }

    @Test("An installation in a subdirectory is preserved")
    func subdirectory() throws {
        let address = try ServerAddress.parse("https://example.com/nextcloud/")
        #expect(address.url.absoluteString == "https://example.com/nextcloud")
        #expect(address.url(path: "/ocs/v2.php/cloud/user").absoluteString
            == "https://example.com/nextcloud/ocs/v2.php/cloud/user")
    }

    @Test("A URL copied out of the Talk web UI is reduced to the server root",
          arguments: [
            "https://cloud.example.com/index.php/apps/spreed/#/call/abc123",
            "https://cloud.example.com/apps/spreed/",
            "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room",
            "https://cloud.example.com/remote.php/dav/files/alice"
          ])
    func pastedFromBrowser(_ input: String) throws {
        let address = try ServerAddress.parse(input)
        #expect(address.url.absoluteString == "https://cloud.example.com")
    }

    @Test("A subdirectory install still survives a pasted app URL")
    func subdirectoryWithAppPath() throws {
        let address = try ServerAddress.parse("https://example.com/nextcloud/index.php/apps/spreed/#/call/x")
        #expect(address.url.absoluteString == "https://example.com/nextcloud")
    }

    @Test("Credentials and queries in the URL are discarded")
    func stripsUserInfo() throws {
        let address = try ServerAddress.parse("https://alice:secret@cloud.example.com/?foo=bar#frag")
        #expect(address.url.absoluteString == "https://cloud.example.com")
    }

    @Test("Plain HTTP is refused")
    func refusesHTTP() {
        #expect(throws: TalkError.insecureServer(host: "cloud.example.com")) {
            try ServerAddress.parse("http://cloud.example.com")
        }
    }

    @Test("Plain HTTP to a local address is allowed only with the developer opt-in")
    func allowsLocalHTTPWhenOptedIn() throws {
        #expect(throws: TalkError.self) {
            try ServerAddress.parse("http://localhost:8080")
        }
        let address = try ServerAddress.parse("http://localhost:8080", allowInsecureHTTP: true)
        #expect(address.url.absoluteString == "http://localhost:8080")

        // …and even then, only for addresses that are plainly local.
        #expect(throws: TalkError.insecureServer(host: "cloud.example.com")) {
            try ServerAddress.parse("http://cloud.example.com", allowInsecureHTTP: true)
        }
    }

    @Test("Nonsense is rejected", arguments: ["", "   ", "ftp://cloud.example.com", "https://"])
    func rejectsGarbage(_ input: String) {
        #expect(throws: TalkError.self) { try ServerAddress.parse(input) }
    }

    @Test("Local host detection", arguments: [
        ("localhost", true), ("127.0.0.1", true), ("nextcloud.local", true),
        ("192.168.1.50", true), ("10.0.0.5", true), ("172.16.0.1", true),
        ("172.32.0.1", false), ("cloud.example.com", false), ("notlocalhost.com", false)
    ])
    func localHostDetection(_ input: (String, Bool)) {
        #expect(ServerAddress.isLocalHost(input.0) == input.1)
    }
}
