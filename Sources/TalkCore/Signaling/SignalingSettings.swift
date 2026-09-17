import Foundation

/// What Nextcloud says about reaching its signaling server: which server, and the short-lived
/// credentials for signing in to it. Asked for again before every fresh sign-in, because the
/// token in it expires within minutes.
struct SignalingSettings: Sendable, Equatable {
    /// `external` when a High Performance Backend is configured; anything else means Talk's
    /// built-in signaling, which kvidr doesn't connect to.
    var mode: String
    var server: String
    var userID: String?
    /// Sign-in for protocol 2.0: a JWT the signaling server checks against the key Nextcloud
    /// publishes in its capabilities.
    var helloToken: String?
    /// Sign-in for protocol 1.0: a ticket the signaling server checks with Nextcloud itself.
    var ticket: String?

    var isExternal: Bool { mode == "external" && !server.isEmpty }

    /// The websocket to open: the server's address with `http(s)` as `ws(s)`, and `/spreed`
    /// on the end — as Talk's own web app builds it. Only a secure socket is accepted: the
    /// token travels over it.
    var websocketURL: URL? {
        var address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("https://") {
            address = "wss://" + address.dropFirst("https://".count)
        } else if address.hasPrefix("http://") {
            return nil
        }
        guard address.hasPrefix("wss://") else { return nil }
        while address.hasSuffix("/") { address.removeLast() }
        guard let url = URL(string: address + "/spreed"), url.host() != nil else { return nil }
        return url
    }
}

struct SignalingSettingsDTO: Decodable, Sendable {
    let signalingMode: String?
    let server: String?
    let userId: String?
    let ticket: String?
    let helloAuthParams: HelloAuthParams?

    struct HelloAuthParams: Decodable, Sendable {
        let v2: Token?
        struct Token: Decodable, Sendable { let token: String? }
        private enum CodingKeys: String, CodingKey { case v2 = "2.0" }
    }

    private enum CodingKeys: String, CodingKey {
        case signalingMode, server, userId, ticket, helloAuthParams
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signalingMode = try? container.decodeIfPresent(String.self, forKey: .signalingMode)
        // A list of servers in some configurations; any of them will do.
        if let single = try? container.decodeIfPresent(String.self, forKey: .server) {
            server = single
        } else {
            server = (try? container.decodeIfPresent([String].self, forKey: .server))?.first
        }
        userId = Lenient.string(container, .userId)
        ticket = try? container.decodeIfPresent(String.self, forKey: .ticket)
        helloAuthParams = try? container.decodeIfPresent(HelloAuthParams.self, forKey: .helloAuthParams)
    }

    func model() -> SignalingSettings {
        SignalingSettings(
            mode: signalingMode ?? "",
            server: server ?? "",
            userID: userId,
            helloToken: helloAuthParams?.v2?.token,
            ticket: ticket
        )
    }
}

actor SignalingSettingsService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    func settings() async throws(TalkError) -> SignalingSettings {
        let response = try await client.require(OCSRequest.get(Endpoint.signalingSettings), as: SignalingSettingsDTO.self)
        return response.value.model()
    }
}
