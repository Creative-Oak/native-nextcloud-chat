import Foundation
import Testing
@testable import TalkCore

/// Routes stub responses by path, so a whole multi-request flow can be scripted.
private func router(_ routes: [String: @Sendable (HTTPRequest, Int) -> HTTPResponse]) -> StubTransport {
    let counts = Counter()
    return StubTransport { request in
        let path = request.url.path
        guard let route = routes.first(where: { path.hasSuffix($0.key) })?.value else {
            return .status(404)
        }
        return route(request, counts.next(for: path))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(for key: String) -> Int {
        lock.withLock {
            let value = counts[key, default: 0]
            counts[key] = value + 1
            return value
        }
    }
}

private let startBody = """
{"poll":{"token":"poll-token-123","endpoint":"https://cloud.example.com/login/v2/poll"},
 "login":"https://cloud.example.com/login/v2/flow/abc"}
"""

private let userBody = ocsEnvelope(#"{"id":"alice","display-name":"Alice Andersen","email":"alice@example.com"}"#)

@Suite("Login Flow v2")
struct LoginFlowTests {
    private func service(
        _ transport: any HTTPTransport,
        store: any CredentialStore = InMemoryCredentialStore(),
        allowsInsecure: Bool = false
    ) -> AuthenticationService {
        AuthenticationService(
            transport: transport,
            credentialStore: store,
            userAgent: "kvidr/1.0 (Mac)",
            isInsecureHTTPAllowed: { allowsInsecure },
            sleeper: { _ in }        // no real waiting in tests
        )
    }

    @Test("Start returns the browser URL and the poll credentials")
    func beginsFlow() async throws {
        let transport = StubTransport(json: startBody)
        let session = try await service(transport).beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))

        #expect(session.loginURL.absoluteString == "https://cloud.example.com/login/v2/flow/abc")
        #expect(session.pollToken == "poll-token-123")

        let request = try #require(transport.lastRequest)
        #expect(request.method == .post)
        #expect(request.url.path == "/index.php/login/v2")
        // The User-Agent becomes the app password's name in the user's settings.
        #expect(request.headers["User-Agent"] == "kvidr/1.0 (Mac)")
    }

    @Test("A login URL that isn't HTTPS is refused before the browser ever opens")
    func refusesInsecureLoginURL() async throws {
        let transport = StubTransport(json: """
        {"poll":{"token":"t","endpoint":"http://evil.example.com/poll"},"login":"http://evil.example.com/flow"}
        """)
        await #expect(throws: TalkError.self) {
            try await service(transport).beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        }
    }

    @Test("The developer opt-in allows a local HTTP login flow, and only a local one")
    func insecureLocalFlow() async throws {
        let localBody = """
        {"poll":{"token":"t","endpoint":"http://localhost:8080/login/v2/poll"},
         "login":"http://localhost:8080/login/v2/flow/abc"}
        """
        let transport = StubTransport(json: localBody)
        let session = try await service(transport, allowsInsecure: true)
            .beginLogin(server: try ServerAddress.parse("http://localhost:8080", allowInsecureHTTP: true))
        #expect(session.loginURL.scheme == "http")

        // The same opt-in must not open the door for a public host.
        let publicBody = """
        {"poll":{"token":"t","endpoint":"http://cloud.example.com/login/v2/poll"},
         "login":"http://cloud.example.com/login/v2/flow/abc"}
        """
        let publicTransport = StubTransport(json: publicBody)
        await #expect(throws: TalkError.insecureServer(host: "cloud.example.com")) {
            try await service(publicTransport, allowsInsecure: true)
                .beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        }
    }

    @Test("A poll endpoint on another host is refused, not merely logged")
    func refusesPollEndpointOnAnotherHost() async throws {
        // The shape of a relay: a genuine login URL for the server the user typed, so the
        // browser shows the right domain and the right padlock, with the poll — and so the
        // app password — aimed at a host the attacker owns.
        let transport = StubTransport(json: """
        {"poll":{"token":"t","endpoint":"https://evil.example/login/v2/poll"},
         "login":"https://cloud.example.com/login/v2/flow/abc"}
        """)
        await #expect(throws: TalkError.unexpectedResponse("login/v2 poll URL is not on cloud.example.com")) {
            try await service(transport).beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        }
    }

    @Test("A login URL on another host never reaches the browser")
    func refusesLoginURLOnAnotherHost() async throws {
        let transport = StubTransport(json: """
        {"poll":{"token":"t","endpoint":"https://cloud.example.com/login/v2/poll"},
         "login":"https://evil.example/login/v2/flow/abc"}
        """)
        await #expect(throws: TalkError.unexpectedResponse("login/v2 login URL is not on cloud.example.com")) {
            try await service(transport).beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        }
    }

    @Test("Same host on another port is a different origin")
    func refusesLoginURLOnAnotherPort() async throws {
        let transport = StubTransport(json: """
        {"poll":{"token":"t","endpoint":"https://cloud.example.com/login/v2/poll"},
         "login":"https://cloud.example.com:8443/login/v2/flow/abc"}
        """)
        await #expect(throws: TalkError.unexpectedResponse("login/v2 login URL is not on cloud.example.com")) {
            try await service(transport).beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        }
    }

    @Test("An installation in a subdirectory is still the same origin")
    func acceptsSubdirectoryInstallation() async throws {
        // The origin check compares scheme, host and port only. Nextcloud can live under a
        // path, and the login and poll URLs sit at different paths under it by design, so
        // comparing more than the origin would break a perfectly ordinary install.
        let transport = StubTransport(json: """
        {"poll":{"token":"t","endpoint":"https://cloud.example.com:443/nextcloud/login/v2/poll"},
         "login":"https://CLOUD.example.com/nextcloud/login/v2/flow/abc"}
        """)
        let session = try await service(transport)
            .beginLogin(server: try ServerAddress.parse("https://cloud.example.com/nextcloud"))
        #expect(session.pollToken == "t")
    }

    @Test("A poll response claiming another server is refused before anything is stored")
    func refusesPollResponseForAnotherServer() async throws {
        // Both URLs are on the right origin; only the credential's own claimed origin is
        // wrong. That is what a server relaying someone else's flow ends up returning.
        let pollBody = #"{"server":"https://cloud.victim.example","loginName":"alice","appPassword":"secret-app-password"}"#
        let transport = router([
            "/index.php/login/v2": { _, _ in .json(startBody) },
            "/login/v2/poll": { _, _ in .json(pollBody) }
        ])
        let address = try ServerAddress.parse("https://cloud.example.com")
        let store = InMemoryCredentialStore()
        let service = service(transport, store: store)

        let session = try await service.beginLogin(server: address)
        await #expect(throws: TalkError.unexpectedResponse("login/v2 poll returned credentials for another server")) {
            try await service.completeLogin(session)
        }
        #expect(try store.credentials(for: Account.identifier(server: address, loginName: "alice")) == nil)
    }

    @Test("Origin comparison is scheme, host and port, and nothing else")
    func originComparison() throws {
        let server = try ServerAddress.parse("https://cloud.example.com/nextcloud")
        #expect(AuthenticationService.isSameOrigin(URL(string: "https://cloud.example.com/anything")!, as: server))
        #expect(AuthenticationService.isSameOrigin(URL(string: "https://CLOUD.EXAMPLE.com:443/x")!, as: server))
        #expect(!AuthenticationService.isSameOrigin(URL(string: "https://evil.example/nextcloud")!, as: server))
        #expect(!AuthenticationService.isSameOrigin(URL(string: "https://cloud.example.com:8443/nextcloud")!, as: server))
        #expect(!AuthenticationService.isSameOrigin(URL(string: "http://cloud.example.com/nextcloud")!, as: server))
        // A hostless URL can't be pinned to an origin, so it matches nothing.
        #expect(!AuthenticationService.isSameOrigin(URL(string: "file:///etc/passwd")!, as: server))
    }

    @Test("404 from the poll endpoint means 'not yet', not failure")
    func pollPending() async throws {
        let transport = router([
            "/index.php/login/v2": { _, _ in .json(startBody) },
            "/login/v2/poll": { _, _ in .status(404) }
        ])
        let service = service(transport)
        let session = try await service.beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        let result = try await service.poll(session)
        #expect(result == nil)
    }

    @Test("The flow completes once the user grants access, and stores the app password")
    func completesFlow() async throws {
        let pollBody = #"{"server":"https://cloud.example.com","loginName":"alice","appPassword":"secret-app-password"}"#
        let transport = router([
            "/index.php/login/v2": { _, _ in .json(startBody) },
            // The user takes three polls to click Grant access.
            "/login/v2/poll": { _, attempt in attempt < 2 ? .status(404) : .json(pollBody) },
            "/ocs/v2.php/cloud/user": { _, _ in .json(userBody, headers: ["X-Nextcloud-Talk-Hash": "hash-1"]) },
            "/ocs/v2.php/cloud/capabilities": { _, _ in
                .json(String(decoding: (try? Fixture.data("capabilities")) ?? Data(), as: UTF8.self))
            }
        ])
        let store = InMemoryCredentialStore()
        let service = service(transport, store: store)

        let session = try await service.beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        let result = try await service.completeLogin(session)

        #expect(result.account.userID == "alice")
        #expect(result.account.loginName == "alice")
        #expect(result.account.displayName == "Alice Andersen")
        #expect(result.account.email == "alice@example.com")
        #expect(result.account.state == .connected)
        #expect(result.account.talkHash == "hash-1")
        #expect(result.account.capabilities.supportsReactions)

        // The app password is in the credential store, and nowhere else.
        let stored = try #require(try store.credentials(for: result.account.id))
        #expect(stored.appPassword == "secret-app-password")
        #expect(stored.loginName == "alice")
    }

    @Test("A login cancelled after the grant doesn’t still store the app password")
    func cancelAfterGrantStoresNothing() async throws {
        let pollBody = #"{"server":"https://cloud.example.com","loginName":"alice","appPassword":"secret-app-password"}"#
        let transport = CancellingTransport(
            router([
                "/index.php/login/v2": { _, _ in .json(startBody) },
                "/login/v2/poll": { _, _ in .json(pollBody) },
                "/ocs/v2.php/cloud/user": { _, _ in .json(userBody) },
                "/ocs/v2.php/cloud/capabilities": { _, _ in
                    .json(String(decoding: (try? Fixture.data("capabilities")) ?? Data(), as: UTF8.self))
                }
            ]),
            // The user presses Cancel after granting access, while the app is still
            // fetching the account details that come before the keychain write.
            cancelOn: "/ocs/v2.php/cloud/user"
        )
        let address = try ServerAddress.parse("https://cloud.example.com")
        let store = InMemoryCredentialStore()
        let service = service(transport, store: store)
        let session = try await service.beginLogin(server: address)

        let task = Task { try await service.completeLogin(session) }
        transport.arm { task.cancel() }
        let result = await task.result

        #expect(throws: TalkError.cancelled) { try result.get() }
        #expect(try store.credentials(for: Account.identifier(server: address, loginName: "alice")) == nil)
    }

    @Test("The app password never appears in a description or log interpolation")
    func credentialsAreRedacted() {
        let credentials = Credentials(loginName: "alice", appPassword: "super-secret")
        #expect(!"\(credentials)".contains("super-secret"))
        #expect(!String(reflecting: credentials).contains("super-secret"))
        // …but the header still carries it, base64-encoded.
        #expect(credentials.authorizationHeaderValue == "Basic YWxpY2U6c3VwZXItc2VjcmV0")
    }

    @Test("An expired flow gives up instead of polling forever")
    func expiredFlow() async throws {
        let transport = router([
            "/index.php/login/v2": { _, _ in .json(startBody) },
            "/login/v2/poll": { _, _ in .status(404) }
        ])
        let service = service(transport)
        var session = try await service.beginLogin(server: try ServerAddress.parse("https://cloud.example.com"))
        session = LoginFlowSession(
            loginURL: session.loginURL,
            pollEndpoint: session.pollEndpoint,
            pollToken: session.pollToken,
            server: session.server,
            startedAt: Date().addingTimeInterval(-LoginFlowSession.lifetime - 1)
        )
        #expect(session.isExpired())
        await #expect(throws: TalkError.timedOut) { try await service.completeLogin(session) }
    }

    @Test("Polling eases off rather than hammering the server for twenty minutes")
    func pollBackoff() {
        #expect(AuthenticationService.pollDelay(forAttempt: 1) == 1)
        #expect(AuthenticationService.pollDelay(forAttempt: 29) == 1)
        #expect(AuthenticationService.pollDelay(forAttempt: 30) == 2)
        #expect(AuthenticationService.pollDelay(forAttempt: 100) == 5)
    }

    @Test("Probing an address checks for Talk before sending the user to a browser")
    func probeRejectsServerWithoutTalk() async throws {
        let transport = StubTransport(json: ocsEnvelope(#"{"capabilities":{"files":{"undelete":true}}}"#))
        await #expect(throws: TalkError.missingCapability("Nextcloud Talk")) {
            try await service(transport).probe(server: try ServerAddress.parse("https://cloud.example.com"))
        }
        // Anonymous: probing must not require credentials.
        #expect(try #require(transport.lastRequest).headers["Authorization"] == nil)
    }

    @Test("Signing out revokes the app password and clears the keychain item")
    func signOutRevokes() async throws {
        let transport = router([
            "/ocs/v2.php/core/apppassword": { _, _ in .json(ocsEnvelope("[]")) }
        ])
        let store = InMemoryCredentialStore()
        let account = Account(
            server: try ServerAddress.parse("https://cloud.example.com"),
            loginName: "alice",
            userID: "alice"
        )
        try store.store(Credentials(loginName: "alice", appPassword: "secret"), for: account.id)

        let outcome = await service(transport, store: store).signOut(account: account)

        #expect(outcome.isClean)
        #expect(outcome.warning == nil)
        #expect(try store.credentials(for: account.id) == nil)
        let request = try #require(transport.lastRequest)
        #expect(request.method == .delete)
        #expect(request.url.path == "/ocs/v2.php/core/apppassword")
    }

    @Test("Sign-out still clears local credentials when the server can't be reached")
    func signOutWhenOffline() async throws {
        let transport = StubTransport { _ in throw TalkError.offline }
        let store = InMemoryCredentialStore()
        let account = Account(
            server: try ServerAddress.parse("https://cloud.example.com"),
            loginName: "alice",
            userID: "alice"
        )
        try store.store(Credentials(loginName: "alice", appPassword: "secret"), for: account.id)

        let outcome = await service(transport, store: store).signOut(account: account)
        #expect(try store.credentials(for: account.id) == nil)
        // Non-blocking, but not silent: the app password is still live on the server, and
        // saying "revoked" here is how it ends up outliving the account for good.
        #expect(outcome.removedLocally)
        #expect(!outcome.revokedOnServer)
        #expect(outcome.warning != nil)
    }

    @Test("A keychain that won’t open doesn’t silently skip revocation")
    func signOutReportsAKeychainReadFailure() async throws {
        let transport = router([
            "/ocs/v2.php/core/apppassword": { _, _ in .json(ocsEnvelope("[]")) }
        ])
        let account = Account(
            server: try ServerAddress.parse("https://cloud.example.com"),
            loginName: "alice",
            userID: "alice"
        )

        let outcome = await service(transport, store: BrittleCredentialStore(failsRead: true))
            .signOut(account: account)

        // Nothing could be read, so nothing was revoked — which is exactly the case the
        // old `try?` turned into "there was nothing stored" and reported as success.
        #expect(transport.lastRequest == nil)
        #expect(!outcome.revokedOnServer)
        #expect(outcome.warning != nil)
    }

    @Test("A keychain item that can’t be deleted is reported rather than orphaned")
    func signOutReportsAKeychainDeleteFailure() async throws {
        let transport = router([
            "/ocs/v2.php/core/apppassword": { _, _ in .json(ocsEnvelope("[]")) }
        ])
        let account = Account(
            server: try ServerAddress.parse("https://cloud.example.com"),
            loginName: "alice",
            userID: "alice"
        )
        let store = BrittleCredentialStore(failsRemove: true)
        try store.store(Credentials(loginName: "alice", appPassword: "secret"), for: account.id)

        let outcome = await service(transport, store: store).signOut(account: account)

        #expect(outcome.revokedOnServer)
        #expect(!outcome.removedLocally)
        #expect(!outcome.isClean)
        #expect(outcome.warning != nil)
    }

    @Test("Signing out an account with nothing stored has nothing to warn about")
    func signOutWithNothingStoredIsClean() async throws {
        let transport = StubTransport(json: "{}")
        let account = Account(
            server: try ServerAddress.parse("https://cloud.example.com"),
            loginName: "alice",
            userID: "alice"
        )

        let outcome = await service(transport).signOut(account: account)

        #expect(outcome.isClean)
        #expect(outcome.warning == nil)
        #expect(transport.lastRequest == nil)
    }
}

/// A store that fails on demand, so the sign-out reporting can be exercised without a real
/// keychain to lock, deny or break.
private final class BrittleCredentialStore: CredentialStore, @unchecked Sendable {
    struct Failure: Error {}

    private let inner = InMemoryCredentialStore()
    private let failsRead: Bool
    private let failsRemove: Bool

    init(failsRead: Bool = false, failsRemove: Bool = false) {
        self.failsRead = failsRead
        self.failsRemove = failsRemove
    }

    func credentials(for accountID: String) throws -> Credentials? {
        if failsRead { throw Failure() }
        return try inner.credentials(for: accountID)
    }

    func store(_ credentials: Credentials, for accountID: String) throws {
        try inner.store(credentials, for: accountID)
    }

    func remove(for accountID: String) throws {
        if failsRemove { throw Failure() }
        try inner.remove(for: accountID)
    }
}

/// Cancels a task of the test’s choosing the moment a given path is requested, which is
/// how "the user pressed Cancel while the flow was finishing" is staged without a race.
private final class CancellingTransport: HTTPTransport, @unchecked Sendable {
    private let inner: StubTransport
    private let path: String
    private let lock = NSLock()
    private var pressCancel: (@Sendable () -> Void)?

    init(_ inner: StubTransport, cancelOn path: String) {
        self.inner = inner
        self.path = path
    }

    func arm(_ pressCancel: @escaping @Sendable () -> Void) {
        lock.withLock { self.pressCancel = pressCancel }
    }

    func send(_ request: HTTPRequest) async throws(TalkError) -> HTTPResponse {
        if request.url.path.hasSuffix(path) {
            // The test arms this immediately after creating the task, so yield to it
            // rather than racing it. Bounded, so a mistake in a test hangs nothing.
            var spins = 0
            while lock.withLock({ self.pressCancel }) == nil, spins < 10_000 {
                spins += 1
                await Task.yield()
            }
            lock.withLock { self.pressCancel }?()
        }
        return try await inner.send(request)
    }
}
