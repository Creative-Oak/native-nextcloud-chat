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
    /// Read at the moment it matters rather than captured at init, so toggling the
    /// developer setting takes effect without relaunching.
    private let isInsecureHTTPAllowed: @Sendable () -> Bool
    /// Injected so the polling loop can be tested without spending real seconds.
    private let sleeper: @Sendable (Double) async throws -> Void

    init(
        transport: any HTTPTransport,
        credentialStore: any CredentialStore,
        userAgent: String,
        isInsecureHTTPAllowed: @escaping @Sendable () -> Bool = { false },
        sleeper: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.userAgent = userAgent
        self.isInsecureHTTPAllowed = isInsecureHTTPAllowed
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

        // Both URLs are server-supplied strings, and both are acted on with the user's
        // trust behind them: the login URL goes to the default browser, the poll endpoint
        // receives a token that is about to become an app password. A server that can name
        // a *different* origin for either one can broker someone else's login flow through
        // us — the user sees their real Nextcloud in the browser and approves it, and the
        // credential that comes back belongs to that server, not this one.
        //
        // A server whose overwrite.cli.url points elsewhere used to be the reason this was
        // only a warning. It isn't a good enough one: nothing distinguishes that server
        // from a relay standing in front of one, and a user on such an install can simply
        // type the overwritten address instead, which is the address their server believes
        // it lives at anyway.
        try validate(url: loginURL, purpose: "login", matches: server)
        try validate(url: pollEndpoint, purpose: "poll", matches: server)

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
            // The response names the server the password was minted for. We don't use it
            // as an address — see `finishLogin` — but we do hold it to the origin the user
            // typed, so a credential issued somewhere else is refused rather than stored.
            guard let claimed = URL(string: dto.server),
                  Self.isSameOrigin(claimed, as: session.server)
            else {
                throw .unexpectedResponse("login/v2 poll returned credentials for another server")
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
        // The address the user typed is the one the credential is used against. The poll
        // response's own `server` field is never adopted in its place — a server that could
        // redirect us here would be aiming an app password the user approved for one origin
        // at another. It is checked against this origin in ``poll(_:)`` instead, so by the
        // time we get here the two are known to agree.
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

        // Cancel has to mean cancel. Everything above this line is recoverable — a flow
        // the user backed out of leaves an app password they can revoke — but storing it
        // signs the app in behind them, at the very server they were trying to get away from.
        if Task.isCancelled { throw .cancelled }

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
    ///
    /// Still never throws: being unable to reach the server must not leave the user stuck
    /// signed in. But it reports what it actually managed, because the alternative is
    /// telling someone their access was revoked while a working app password is still
    /// sitting on the server, or in their keychain with no account left to point at it.
    func signOut(account: Account) async -> SignOutOutcome {
        var outcome = SignOutOutcome()

        // Deliberately not `try?`: that flattened "the keychain wouldn’t open" into
        // "nothing was stored", and the two want opposite answers — the first means a live
        // credential is probably still here and the user needs to hear about it.
        var credentials: Credentials? = nil
        do {
            credentials = try credentialStore.credentials(for: account.id)
            // Nothing stored is nothing of ours left to revoke.
            outcome.revokedOnServer = credentials == nil
        } catch {
            Log.auth.error("Couldn’t read the app password to revoke it; it may still be live")
        }

        if let credentials {
            let client = OCSClient(server: account.server, credentials: credentials, transport: transport)
            do {
                _ = try await client.send(OCSRequest.delete(Endpoint.appPassword), as: EmptyResponse.self)
                outcome.revokedOnServer = true
                Log.auth.info("Revoked app password for \(account.userID)")
            } catch {
                Log.auth.warning("Couldn’t revoke the app password server-side; removing it locally anyway")
            }
        }

        do {
            try credentialStore.remove(for: account.id)
            outcome.removedLocally = true
        } catch {
            Log.auth.error("Failed to delete keychain item for account")
        }

        return outcome
    }

    private func validate(url: URL, purpose: String, matches server: ServerAddress) throws(TalkError) {
        // Scheme first, so an http:// URL still reports the transport problem rather than
        // the origin one — it is the more useful thing to tell someone.
        try validateScheme(url: url, purpose: purpose)
        guard Self.isSameOrigin(url, as: server) else {
            // The host the server named is deliberately not repeated back: it is attacker
            // text, and this message reaches the log.
            throw .unexpectedResponse("login/v2 \(purpose) URL is not on \(server.host)")
        }
    }

    private func validateScheme(url: URL, purpose: String) throws(TalkError) {
        guard let scheme = url.scheme?.lowercased() else {
            throw .unexpectedResponse("login/v2 \(purpose) URL has no scheme")
        }
        if scheme == "https" { return }
        if scheme == "http", isInsecureHTTPAllowed(), ServerAddress.isLocalHost(url.host() ?? "") { return }
        throw .insecureServer(host: url.host() ?? purpose)
    }

    /// Same scheme, host and port — the web’s own definition of an origin. Path is
    /// deliberately not compared: Nextcloud can live in a subdirectory, and the login and
    /// poll URLs sit at different paths under it by design.
    static func isSameOrigin(_ url: URL, as server: ServerAddress) -> Bool {
        guard let candidate = origin(of: url), let expected = origin(of: server.url) else { return false }
        return candidate == expected
    }

    /// `nil` for anything without both a scheme and a host, which is then never equal to
    /// anything — a URL we can’t pin down an origin for is not one we can trust.
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        // Spelling the default out, so https://host and https://host:443 are one origin.
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

/// What ``AuthenticationService/signOut(account:)`` managed to do.
///
/// Sign-out is best effort by design, so the parts that didn’t happen have to travel back
/// to the UI: the Settings copy promises the app’s access is revoked, and an app password
/// that outlives the account it belonged to is one nothing will ever try to clean up again.
struct SignOutOutcome: Sendable, Equatable {
    /// The app password is dead on the server — either we revoked it, or there was none
    /// stored to revoke.
    var revokedOnServer = false
    /// The keychain item is gone.
    var removedLocally = false

    var isClean: Bool { revokedOnServer && removedLocally }

    /// Short, calm and actionable, in the register of ``TalkError/userMessage``. `nil` when
    /// there is nothing the user needs to do.
    var warning: String? {
        var parts: [String] = []
        if !revokedOnServer {
            parts.append("kvidr couldn’t revoke its own access on the server — remove this device under Security in your Nextcloud settings.")
        }
        if !removedLocally {
            parts.append("The saved app password couldn’t be deleted from your keychain — remove the kvidr item in Keychain Access.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
