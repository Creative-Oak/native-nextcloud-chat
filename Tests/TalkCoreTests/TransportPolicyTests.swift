import Foundation
import Testing
@testable import TalkCore

/// The rules the transport applies to every request, tested away from a live socket.
@Suite("Redirect policy")
struct RedirectPolicyTests {
    @Test("A redirect that stays on the origin the request was aimed at is followed", arguments: [
        ("https://cloud.example.com/ocs/v2.php/cloud/user", "https://cloud.example.com/index.php/whatever"),
        ("https://cloud.example.com:8443/a", "https://cloud.example.com:8443/b"),
        // An explicit default port is the same origin as an omitted one.
        ("https://cloud.example.com/a", "https://cloud.example.com:443/b"),
        ("http://localhost:8080/a", "http://localhost:8080/b")
    ])
    func followsSameOrigin(_ pair: (String, String)) {
        #expect(RedirectPolicy.isSameOrigin(URL(string: pair.0), URL(string: pair.1)))
    }

    /// Each of these used to carry `Authorization: Basic <app password>` — and, on a 307,
    /// the request body — to the host that wrote the `Location`.
    @Test("Anything that leaves the origin is refused", arguments: [
        ("https://cloud.example.com/ocs/v2.php/cloud/user", "https://evil.example/collect"),
        // The classic near-miss: a suffix of the real host, registered by someone else.
        ("https://cloud.example.com/a", "https://cloud.example.com.evil.example/a"),
        ("https://cloud.example.com/a", "https://evil.cloud.example.com/a"),
        // Never a downgrade, even back to the same host.
        ("https://cloud.example.com/a", "http://cloud.example.com/a"),
        ("https://cloud.example.com/a", "https://cloud.example.com:8443/a"),
        ("https://cloud.example.com:8443/a", "https://cloud.example.com/a"),
        ("https://cloud.example.com/a", "file:///etc/passwd"),
        ("https://cloud.example.com/a", "https://user:pw@evil.example/a")
    ])
    func refusesOffOrigin(_ pair: (String, String)) {
        #expect(RedirectPolicy.isSameOrigin(URL(string: pair.0), URL(string: pair.1)) == false)
    }

    @Test("A destination that isn't a usable URL is refused rather than guessed at")
    func refusesUnusable() {
        let origin = URL(string: "https://cloud.example.com/a")
        #expect(RedirectPolicy.isSameOrigin(origin, nil) == false)
        #expect(RedirectPolicy.isSameOrigin(nil, origin) == false)
        #expect(RedirectPolicy.isSameOrigin(origin, URL(string: "mailto:someone@evil.example")) == false)
    }
}

@Suite("Response ceiling")
struct ResponseBudgetTests {
    @Test("A declared Content-Length past the ceiling is refused before a byte is read")
    func refusesDeclaredLength() {
        let budget = ResponseBudget(limit: 1024)
        #expect(budget.permits(declaredLength: 0))
        #expect(budget.permits(declaredLength: 1024))
        #expect(budget.permits(declaredLength: 1025) == false)
        #expect(budget.permits(declaredLength: 8 * 1024 * 1024 * 1024) == false)
        // A chunked response declares nothing, which is why this one has to pass here.
        #expect(budget.permits(declaredLength: -1))
    }

    @Test("A body that declares nothing is counted as it lands, and dropped when it overruns")
    func countsWhatActuallyArrives() {
        var budget = ResponseBudget(limit: 8)
        let firstChunk = budget.accept(Data(repeating: 0x61, count: 5))
        #expect(firstChunk)
        #expect(budget.body.count == 5)

        let secondChunk = budget.accept(Data(repeating: 0x61, count: 3))
        #expect(secondChunk)
        #expect(budget.body.count == 8)

        // One byte past the ceiling: refused, and what had accumulated goes with it.
        let overrun = budget.accept(Data(repeating: 0x61, count: 1))
        #expect(overrun == false)
        #expect(budget.body.isEmpty)
    }

    @Test("API calls are held to the tight ceiling, not the one meant for file downloads")
    func apiCallsUseTheTightCeiling() async throws {
        #expect(HTTPRequest.apiResponseLimit < HTTPRequest.transferResponseLimit)

        let transport = StubTransport(json: ocsEnvelope("[]"))
        let client = OCSClient(
            server: try ServerAddress.parse("https://cloud.example.com"),
            credentials: Credentials(loginName: "alice", appPassword: "pw"),
            transport: transport
        )
        _ = try await client.send(OCSRequest.get(Endpoint.rooms), as: [String].self)
        #expect(transport.lastRequest?.maximumResponseSize == HTTPRequest.apiResponseLimit)
    }
}

@Suite("Retry-After")
struct RetryAfterTests {
    @Test("The server's number is honoured, but only inside our own range")
    func clampsIntoRange() {
        let backoff = Backoff(base: 1, maximum: 60, jitter: 0)
        // A negative used to sleep for no time at all and come straight back for more.
        #expect(backoff.delay(forAttempt: 1, after: .rateLimited(retryAfter: -1)) == 1)
        #expect(backoff.delay(forAttempt: 1, after: .rateLimited(retryAfter: 0)) == 1)
        // …and a huge one used to park sync for about thirty years.
        #expect(backoff.delay(forAttempt: 1, after: .rateLimited(retryAfter: 999_999_999)) == 60)
        #expect(backoff.delay(forAttempt: 1, after: .rateLimited(retryAfter: 30)) == 30)
        #expect(backoff.delay(forAttempt: 1, after: .rateLimited(retryAfter: .infinity)) == 60)
    }

    @Test("A header that isn't a finite count of seconds is ignored", arguments: [
        "-1", "nan", "inf", "-inf", "", "  ", "later", "Wed, 21 Oct 2015 07:28:00 GMT"
    ])
    func ignoresNonsense(_ raw: String) {
        #expect(HTTPHeaders(["Retry-After": raw]).retryAfter == nil)
    }

    @Test("An ordinary Retry-After still comes through")
    func acceptsSeconds() {
        #expect(HTTPHeaders(["Retry-After": "30"]).retryAfter == 30)
        #expect(HTTPHeaders(["retry-after": "0"]).retryAfter == 0)
    }
}

@Suite("Server error copy")
struct ServerTextTests {
    @Test("The server's words are attributed to it, never spoken in the app's voice")
    func attributesServerText() {
        let phish = "Your session has expired. Re-enter your password at https://evil.example/login"
        #expect(TalkError.forbidden(message: phish).userMessage == "The server says: “\(phish)”")
        #expect(TalkError.forbidden(message: nil).userMessage == "You don’t have permission to do that.")
    }

    @Test("Server text is bounded and stripped of control characters")
    func boundsServerText() {
        let long = String(repeating: "a", count: 5_000)
        let bounded = TalkError.sanitizedServerText(long)
        #expect(bounded != nil)
        // The cap plus the ellipsis that says it was cut.
        #expect((bounded?.count ?? 0) <= TalkError.serverTextLimit + 1)

        let stripped = TalkError.sanitizedServerText("one\nline\u{1B}[2J")
        #expect(stripped == "one line [2J")

        let blank = TalkError.sanitizedServerText("   ")
        #expect(blank == nil)

        let absent = TalkError.sanitizedServerText(nil)
        #expect(absent == nil)
    }
}
