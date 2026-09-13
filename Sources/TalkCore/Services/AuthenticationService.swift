import Foundation

/// An in-progress Login Flow v2 session.
///
/// Deliberately not `Codable` and never persisted: the poll token is a bearer credential
/// for 20 minutes and must not outlive the attempt. ``AuthenticationService`` drops it as
/// soon as the flow completes or is cancelled.
struct LoginFlowSession: Sendable, Equatable {
    /// Open this in the user's default browser.
    let loginURL: URL
    let pollEndpoint: URL
    let pollToken: String
    let server: ServerAddress
    let startedAt: Date

    /// The server gives the flow 20 minutes.
    static let lifetime: TimeInterval = 20 * 60

    func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) >= Self.lifetime
    }

    static func == (lhs: LoginFlowSession, rhs: LoginFlowSession) -> Bool {
        lhs.loginURL == rhs.loginURL && lhs.pollToken == rhs.pollToken
    }
}

struct AuthenticatedAccount: Sendable {
    let account: Account
    let credentials: Credentials
}

/// Login Flow v2, plus credential verification and revocation.
///
/// See docs/NEXTCLOUD_API.md § 2. The app password never leaves this service except into
/// the ``CredentialStore``; it is never logged, never written to preferences, and never
/// included in an error message.
actor AuthenticationService {
    private let transport: any HTTPTransport
    private let credentialStore: any CredentialStore
    private let userAgent: String
    private let allowInsecureHTTP: Bool
    /// Injected so the polling loop can be tested without spending real seconds.
    private let sleeper: @Sendable (Double) async throws -> Void

    init(
        transport: any HTTPTransport,
        credentialStore: any CredentialStore,
        userAgent: String,
        allowInsecureHTTP: Bool = false,
        sleeper: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.userAgent = userAgent
        self.allowInsecureHTTP = allowInsecureHTTP
        self.sleeper = sleeper
    }

    // MARK: - Probing

    /// Checks that an address is actually a Nextcloud with Talk installed, before the user
    /// is sent to a browser. Anonymous — the capabilities endpoint needs no credentials.
    func probe(server: ServerAddress) async throws(TalkError) -> TalkCapabilities {
        let client = OCSClient(server: server, credentials: nil, transport: transport)
        var request = OCSRequest.get(Endpoint.capabilities)
        request.requiresAuthentication = false
        let response = try await client.require(request, as: CapabilitiesDTO.self)
        guard let capabilities = response.value.talkCapabilities() else {
            throw .missingCapability("Nextcloud Talk")
        }
        guard capabilities.supportsChat else {
            throw .missingCapability("a supported Talk version (chat-v2)")
        }
        return capabilities
    }

    // MARK: - Login Flow v2

    /// `POST /index.php/login/v2`.
    func beginLogin(server: ServerAddress) async throws(TalkError) -> LoginFlowSession {
        let request = HTTPRequest(
            method: .post,
            url: server.url(path: Endpoint.loginFlowStart),
            // The User-Agent becomes the app password's name in the user's security
            // settings, so it has to be recognisable.
            headers: ["User-Agent": userAgent, "Accept": "application/json"],
            body: nil,
            timeout: 30
        )

        let response = try await transport.send(request)
        guard (200...299).contains(response.status) else {
            throw TalkError.from(status: response.status, headers: response.headers)
        }

        let dto: LoginFlowStartDTO
        do {
            dto = try JSONDecoder().decode(LoginFlowStartDTO.self, from: response.body)
        } catch {
            throw .decoding(context: "login/v2 start")
        }

        guard let loginURL = URL(string: dto.login),
              let pollEndpoint = URL(string: dto.poll.endpoint)
        else { throw .unexpectedResponse("login/v2 returned an unusable URL") }

        try validate(url: loginURL, purpose: "login")
        try validate(url: pollEndpoint, purpose: "poll")

        if pollEndpoint.host() != server.url.host() {
            // Legitimate when overwrite.cli.url points elsewhere, but worth a breadcrumb.
            Log.auth.warning("Login flow poll host differs from the entered server host")
        }

        Log.auth.info("Started login flow for \(server.host)")
        return LoginFlowSession(
            loginURL: loginURL,
            pollEndpoint: pollEndpoint,
            pollToken: dto.poll.token,
            server: server,
            startedAt: Date()
        )
    }

    /// One poll. `nil` means "not granted yet, keep waiting" — the server answers 404 for
    /// that, which is documented behaviour and not an error.
    func poll(_ session: LoginFlowSession) async throws(TalkError) -> Credentials? {
        let request = HTTPRequest(
            method: .post,
            url: session.pollEndpoint,
            headers: [
                "User-Agent": userAgent,
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
            ],
            body: OCSClient.formEncode(["token": session.pollToken]),
            timeout: 30
        )

        let response = try await transport.send(request)
        switch response.status {
        case 200:
            let dto: LoginFlowPollDTO
            do {
                dto = try JSONDecoder().decode(LoginFlowPollDTO.self, from: response.body)
            } catch {
                throw .decoding(context: "login/v2 poll")
            }
            guard !dto.appPassword.isEmpty, !dto.loginName.isEmpty else {
                throw .unexpectedResponse("login/v2 poll returned empty credentials")
            }
            return Credentials(loginName: dto.loginName, appPassword: dto.appPassword)
        case 404:
            return nil
        default:
            throw TalkError.from(status: response.status, headers: response.headers)
        }
    }

    /// Polls until the user grants access, the flow expires, or the task is cancelled.
    ///
    /// The documented cadence is once per second; we start there and ease off, because a
    /// user who walked away shouldn't cost the server 1200 requests.
    func completeLogin(_ session: LoginFlowSession) async throws(TalkError) -> AuthenticatedAccount {
        var attempt = 0
        while !session.isExpired() {
            if Task.isCancelled { throw .cancelled }

            if let credentials = try await poll(session) {
                return try await finishLogin(session: session, credentials: credentials)
            }

            attempt += 1
            let delay = Self.pollDelay(forAttempt: attempt)
            do {
                try await sleeper(delay)
            } catch {
                throw .cancelled
            }
        }
        throw .timedOut
    }

    /// 1 s for the first half-minute (the common case: the user is right there), then 2 s,
    /// then 5 s for the long tail.
    static func pollDelay(forAttempt attempt: Int) -> Double {
        switch attempt {
        case ..<30: 1
        case ..<60: 2
        default: 5
        }
    }

    private func finishLogin(
        session: LoginFlowSession,
        credentials: Credentials
    ) async throws(TalkError) -> AuthenticatedAccount {
        // The poll response's `server` is authoritative — it reflects overwrite.cli.url,
        // which is the URL the server believes it lives at.
        let server = session.server
        let client = OCSClient(server: server, credentials: credentials, transport: transport)

        let user = try await client.require(OCSRequest.get(Endpoint.user), as: UserDTO.self)
        let capabilities = try await client.require(
            OCSRequest.get(Endpoint.capabilities), as: CapabilitiesDTO.self
        )
        guard let talk = capabilities.value.talkCapabilities() else {
            throw .missingCapability("Nextcloud Talk")
        }

        let account = Account(
            server: server,
            loginName: credentials.loginName,
            userID: user.value.id,
            displayName: user.value.displayName ?? "",
            email: user.value.email,
            state: .connected,
            capabilities: talk,
            talkHash: user.headers.talkHash ?? capabilities.headers.talkHash
        )

        do {
            try credentialStore.store(credentials, for: account.id)
        } catch {
            throw .unexpectedResponse("Couldn’t save credentials to the keychain")
        }

        Log.auth.info("Authenticated \(account.userID) on \(server.host)")
        return AuthenticatedAccount(account: account, credentials: credentials)
    }

    // MARK: - Verification and sign-out

    /// Confirms stored credentials still work. Used at launch; a 401 here flips the account
    /// into `needsReauthentication` rather than silently failing every later call.
    func verify(account: Account) async throws(TalkError) -> UserDTO {
        // `try?` flattens the throwing-optional, so this covers both "keychain failed"
        // and "no item stored".
        guard let credentials = try? credentialStore.credentials(for: account.id) else {
            throw .notAuthenticated
        }
        let client = OCSClient(server: account.server, credentials: credentials, transport: transport)
        return try await client.require(OCSRequest.get(Endpoint.user), as: UserDTO.self).value
    }

    /// Removes the account: revokes the app password server-side (best effort — a revoked
    /// or unreachable server must not block sign-out) and deletes the keychain item.
    func signOut(account: Account) async {
        if let credentials = try? credentialStore.credentials(for: account.id) {
            let client = OCSClient(server: account.server, credentials: credentials, transport: transport)
            do {
                _ = try await client.send(OCSRequest.delete(Endpoint.appPassword), as: EmptyResponse.self)
                Log.auth.info("Revoked app password for \(account.userID)")
            } catch {
                Log.auth.warning("Couldn’t revoke the app password server-side; removing it locally anyway")
            }
        }
        do {
            try credentialStore.remove(for: account.id)
        } catch {
            Log.auth.error("Failed to delete keychain item for account")
        }
    }

    private func validate(url: URL, purpose: String) throws(TalkError) {
        guard let scheme = url.scheme?.lowercased() else {
            throw .unexpectedResponse("login/v2 \(purpose) URL has no scheme")
        }
        if scheme == "https" { return }
        if scheme == "http", allowInsecureHTTP, ServerAddress.isLocalHost(url.host() ?? "") { return }
        throw .insecureServer(host: url.host() ?? purpose)
    }
}

/// For endpoints whose success body carries nothing we need.
struct EmptyResponse: Decodable, Sendable {
    init() {}
    init(from decoder: any Decoder) throws {}
}

private struct LoginFlowStartDTO: Decodable, Sendable {
    struct Poll: Decodable, Sendable {
        let token: String
        let endpoint: String
    }
    let poll: Poll
    let login: String
}

private struct LoginFlowPollDTO: Decodable, Sendable {
    let server: String
    let loginName: String
    let appPassword: String
}
