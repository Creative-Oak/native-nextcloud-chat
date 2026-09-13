import Foundation

/// Describes one OCS call. Services build these; nothing else touches URLs or headers.
struct OCSRequest: Sendable {
    var method: HTTPMethod = .get
    /// Server-relative, e.g. `/ocs/v2.php/apps/spreed/api/v4/room`.
    var path: String
    var query: [URLQueryItem] = []
    /// Form-encoded body. Nextcloud's OCS endpoints take `application/x-www-form-urlencoded`.
    var form: [String: String]?
    var timeout: TimeInterval = 30
    var requiresAuthentication = true

    static func get(_ path: String, query: [URLQueryItem] = []) -> OCSRequest {
        OCSRequest(method: .get, path: path, query: query)
    }

    static func post(_ path: String, form: [String: String] = [:]) -> OCSRequest {
        OCSRequest(method: .post, path: path, form: form)
    }

    static func put(_ path: String, form: [String: String] = [:]) -> OCSRequest {
        OCSRequest(method: .put, path: path, form: form)
    }

    static func delete(_ path: String, form: [String: String] = [:]) -> OCSRequest {
        OCSRequest(method: .delete, path: path, form: form.isEmpty ? nil : form)
    }
}

/// The only place in the app that speaks HTTP to Nextcloud.
///
/// Responsibilities: OCS headers, Basic auth, envelope decoding, mapping every failure
/// onto ``TalkError``, and noticing when the server's Talk hash changes so capabilities
/// can be refreshed.
actor OCSClient {
    let server: ServerAddress
    private let transport: any HTTPTransport
    private var credentials: Credentials?

    /// Last `X-Nextcloud-Talk-Hash` seen. A change means the server's Talk config moved
    /// and the cached capabilities are stale.
    private(set) var talkHash: String?
    private var talkHashHandler: (@Sendable (String) -> Void)?

    init(server: ServerAddress, credentials: Credentials? = nil, transport: any HTTPTransport) {
        self.server = server
        self.credentials = credentials
        self.transport = transport
    }

    func setCredentials(_ credentials: Credentials?) {
        self.credentials = credentials
    }

    var isAuthenticated: Bool { credentials != nil }

    func onTalkHashChange(_ handler: @escaping @Sendable (String) -> Void) {
        talkHashHandler = handler
    }

    // MARK: - Sending

    /// Sends a request and decodes `T` from the OCS envelope.
    ///
    /// Returns `nil` for `304 Not Modified` and `204 No Content` — both are normal
    /// protocol outcomes (the chat long poll returns 304 whenever nothing happened),
    /// not errors.
    func send<T: Decodable & Sendable>(
        _ request: OCSRequest,
        as type: T.Type = T.self
    ) async throws(TalkError) -> OCSResponse<T?> {
        let response = try await perform(request)

        if response.status == 304 || response.status == 204 || response.body.isEmpty {
            try check(status: response.status, headers: response.headers, body: response.body)
            return OCSResponse(value: nil, status: response.status, headers: response.headers)
        }

        let envelope: OCSEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(OCSEnvelope<T>.self, from: response.body)
        } catch {
            // A non-envelope body on a failing status is far more likely to be an HTML
            // error page than a schema problem — report the status, not the decode.
            try check(status: response.status, headers: response.headers, body: response.body)
            throw .decoding(context: "\(request.path): \(error)")
        }

        guard envelope.meta.isSuccess, (200...299).contains(response.status) else {
            let status = (200...299).contains(response.status) ? envelope.meta.statuscode : response.status
            throw TalkError.from(status: status, ocsMessage: envelope.meta.message, headers: response.headers)
        }

        return OCSResponse(value: envelope.data, status: response.status, headers: response.headers)
    }

    /// Same as ``send(_:as:)`` but treats a missing body as a protocol violation.
    func require<T: Decodable & Sendable>(
        _ request: OCSRequest,
        as type: T.Type = T.self
    ) async throws(TalkError) -> OCSResponse<T> {
        let response = try await send(request, as: type)
        guard let value = response.value else {
            throw .unexpectedResponse("\(request.path) returned no data")
        }
        return OCSResponse(value: value, status: response.status, headers: response.headers)
    }

    /// Sends a request whose response body is not OCS JSON (avatars, downloads).
    func sendRaw(_ request: OCSRequest) async throws(TalkError) -> HTTPResponse {
        let response = try await perform(request)
        try check(status: response.status, headers: response.headers, body: response.body)
        return response
    }

    // MARK: - Plumbing

    private func perform(_ request: OCSRequest) async throws(TalkError) -> HTTPResponse {
        var headers: HTTPHeaders = [
            "OCS-APIRequest": "true",
            "Accept": "application/json"
        ]

        if request.requiresAuthentication {
            guard let credentials else { throw .notAuthenticated }
            headers["Authorization"] = credentials.authorizationHeaderValue
        }

        var body: Data?
        if let form = request.form {
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            body = Self.formEncode(form)
        }

        let httpRequest = HTTPRequest(
            method: request.method,
            url: server.url(path: request.path, query: request.query),
            headers: headers,
            body: body,
            timeout: request.timeout
        )

        Log.api.debug("\(request.method.rawValue) \(request.path)")
        let response = try await transport.send(httpRequest)
        noteTalkHash(response.headers)
        return response
    }

    private func check(status: Int, headers: HTTPHeaders, body: Data) throws(TalkError) {
        guard !(200...299).contains(status), status != 304 else { return }
        if headers.isMaintenanceMode { throw .maintenanceMode }
        let message = Self.ocsMessage(from: body)
        throw TalkError.from(status: status, ocsMessage: message, headers: headers)
    }

    private func noteTalkHash(_ headers: HTTPHeaders) {
        guard let hash = headers.talkHash, hash != talkHash else { return }
        let isFirst = talkHash == nil
        talkHash = hash
        if !isFirst {
            Log.api.info("Talk configuration hash changed — capabilities need refreshing")
            talkHashHandler?(hash)
        }
    }

    /// Best-effort extraction of `ocs.meta.message` from an error body.
    private static func ocsMessage(from body: Data) -> String? {
        struct MessageOnly: Decodable {
            let message: String?
            init(from decoder: any Decoder) throws {
                enum RootKey: String, CodingKey { case ocs }
                enum InnerKey: String, CodingKey { case meta }
                enum MetaKey: String, CodingKey { case message }
                let root = try decoder.container(keyedBy: RootKey.self)
                let inner = try root.nestedContainer(keyedBy: InnerKey.self, forKey: .ocs)
                let meta = try inner.nestedContainer(keyedBy: MetaKey.self, forKey: .meta)
                message = try meta.decodeIfPresent(String.self, forKey: .message)
            }
        }
        guard let decoded = try? JSONDecoder().decode(MessageOnly.self, from: body),
              let message = decoded.message, !message.isEmpty, message != "OK"
        else { return nil }
        return message
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}
