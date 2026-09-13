import Foundation

/// A signed-in Nextcloud account.
///
/// This is metadata only — the app password lives in the Keychain, keyed by ``id``.
/// Multi-account is not in the first UI, but nothing here is a singleton: the account id
/// is part of every persistence key and every service is constructed per account.
struct Account: Sendable, Hashable, Identifiable, Codable {
    /// Stable across relaunches and unique per (server, login).
    var id: String
    var server: ServerAddress
    /// What the user typed at the login screen. Not necessarily the user id.
    var loginName: String
    /// Canonical user id from `/ocs/v2.php/cloud/user`; the one that appears in `actorId`.
    var userID: String
    var displayName: String
    var email: String?
    var state: State
    var capabilities: TalkCapabilities
    /// Last `X-Nextcloud-Talk-Hash`; when the server's differs, capabilities are refetched.
    var talkHash: String?
    var addedAt: Date

    enum State: String, Sendable, Codable {
        case connected
        /// The app password was revoked or expired — everything stops until the user re-authenticates.
        case needsReauthentication
        case signedOut
    }

    init(
        id: String? = nil,
        server: ServerAddress,
        loginName: String,
        userID: String,
        displayName: String = "",
        email: String? = nil,
        state: State = .connected,
        capabilities: TalkCapabilities = .empty,
        talkHash: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id ?? Account.identifier(server: server, loginName: loginName)
        self.server = server
        self.loginName = loginName
        self.userID = userID
        self.displayName = displayName
        self.email = email
        self.state = state
        self.capabilities = capabilities
        self.talkHash = talkHash
        self.addedAt = addedAt
    }

    static func identifier(server: ServerAddress, loginName: String) -> String {
        "\(server.url.absoluteString)|\(loginName)"
    }

    var resolvedDisplayName: String { displayName.isEmpty ? loginName : displayName }

    /// Does an actor refer to this account's own user?
    func isMe(_ actor: MessageActor) -> Bool {
        actor.kind == .users && (actor.id == userID || actor.id == loginName)
    }
}
