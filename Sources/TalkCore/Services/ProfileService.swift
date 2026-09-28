import Foundation

/// The signed-in user's profile: read it, and set or remove the picture.
///
/// Editing the rest of the profile is not here on purpose — see ``UserProfile``.
struct ProfileService: Sendable {
    let server: ServerAddress
    let credentials: Credentials
    let userID: String
    let transport: any HTTPTransport
    let client: OCSClient

    func profile() async throws(TalkError) -> UserProfile {
        try await client.require(OCSRequest.get(Endpoint.cloudUser(userID)), as: UserProfileDTO.self).value.profile
    }

    /// Replaces the picture with a square PNG — see ``SquareAvatar``.
    ///
    /// Square matters: the server stores a square image as it is, and answers anything else
    /// with a temporary file and a request to crop it, which is a second round trip this app
    /// has no use for.
    func setAvatar(png: Data) async throws(TalkError) {
        let boundary = "kvidr-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"files[]\"; filename=\"avatar.png\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var headers = avatarHeaders
        headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        let response = try await send(HTTPRequest(method: .post, url: server.url(path: Endpoint.ownAvatar), headers: headers, body: body))
        try Self.checkAvatarResponse(response)
    }

    func removeAvatar() async throws(TalkError) {
        let response = try await send(HTTPRequest(method: .delete, url: server.url(path: Endpoint.ownAvatar), headers: avatarHeaders))
        try Self.checkAvatarResponse(response)
    }

    /// `OCS-APIRequest` is what gets an app-password request past the CSRF check on this
    /// front-page route: `Request::passesCSRFCheck` accepts the header in place of a
    /// request token a browser would carry.
    private var avatarHeaders: HTTPHeaders {
        [
            "Authorization": credentials.authorizationHeaderValue,
            "OCS-APIRequest": "true",
            "Accept": "application/json"
        ]
    }

    private func send(_ request: HTTPRequest) async throws(TalkError) -> HTTPResponse {
        var request = request
        request.maximumResponseSize = HTTPRequest.apiResponseLimit
        return try await transport.send(request)
    }

    /// The avatar controller answers in plain JSON rather than an OCS envelope: success is a
    /// 200 whose `status` is `success` (or, on delete, nothing at all), and a refusal carries
    /// its reason in `data.message` — on a 400, or on a 200 for an image type it won't take.
    static func checkAvatarResponse(_ response: HTTPResponse) throws(TalkError) {
        struct Reply: Decodable {
            struct Payload: Decodable { let message: String? }
            let status: String?
            let data: Payload?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: response.body)
        let reason = TalkError.sanitizedServerText(reply?.data?.message)

        guard (200...299).contains(response.status) else {
            if let reason { throw .ocs(status: response.status, message: reason) }
            throw TalkError.from(status: response.status, headers: response.headers)
        }
        if let status = reply?.status, status != "success" {
            throw .ocs(status: response.status, message: reason ?? String(localized: "Nextcloud didn’t accept that picture.", comment: "Setting a profile picture failed"))
        }
        if reply?.status == nil, let reason {
            throw .ocs(status: response.status, message: reason)
        }
    }
}

/// Pages of the user's own Nextcloud that the app sends them to in the browser.
///
/// Built from the address they signed in with and a fixed path, never from anything a
/// response contains — the same rule the login flow holds its URLs to.
struct ProfileLinks: Sendable {
    let server: ServerAddress
    let userID: String

    var personalInfo: URL { server.url(path: "/index.php/settings/user") }
    var security: URL { server.url(path: "/index.php/settings/user/security") }
    var publicProfile: URL { server.url(path: "/index.php/u/\(Endpoint.segment(userID))") }
}
