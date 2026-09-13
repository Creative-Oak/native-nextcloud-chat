import Foundation

/// One file on its way into a conversation.
struct FileTransfer: Sendable, Identifiable, Equatable {
    enum State: Sendable, Equatable {
        case queued
        /// 0…1 of the bytes sent.
        case uploading(Double)
        /// Uploaded; now being shared into the conversation.
        case sharing
        case completed
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .completed, .failed: true
            default: false
            }
        }

        var fraction: Double {
            switch self {
            case .queued: 0
            case .uploading(let value): value * 0.9    // the share is the last tenth
            case .sharing: 0.95
            case .completed: 1
            case .failed: 0
            }
        }
    }

    let id: UUID
    var fileURL: URL
    var fileName: String
    var byteCount: Int
    var state: State = .queued
    /// Sent with the file so it arrives as one message with a caption.
    var caption: String = ""
    var replyToMessageID: Int?

    init(fileURL: URL, byteCount: Int, caption: String = "", replyToMessageID: Int? = nil) {
        self.id = UUID()
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.byteCount = byteCount
        self.caption = caption
        self.replyToMessageID = replyToMessageID
    }
}

/// Puts a file into the user's Nextcloud and shares it into a conversation.
///
/// Two documented steps, in this order, because Talk can only share a file that already
/// exists in Nextcloud:
///
/// 1. `PUT /remote.php/dav/files/{user}/{path}` — WebDAV upload into the user's own files.
/// 2. `POST /ocs/v2.php/apps/files_sharing/api/v1/shares` with `shareType=10` and the
///    conversation token as `shareWith` — the Files sharing API, not a Talk endpoint.
///
/// Nothing here invents a storage location: the target folder is whatever the server's
/// `config.attachments.folder` capability says, defaulting to Talk's own default of `/Talk`.
actor AttachmentService {
    private let server: ServerAddress
    private let credentials: Credentials
    private let transport: any HTTPTransport
    private let client: OCSClient
    private let userID: String

    init(
        server: ServerAddress,
        credentials: Credentials,
        userID: String,
        transport: any HTTPTransport,
        client: OCSClient
    ) {
        self.server = server
        self.credentials = credentials
        self.userID = userID
        self.transport = transport
        self.client = client
    }

    /// Talk's own default when the server doesn't specify one.
    static let defaultFolder = "/Talk"

    /// Uploads and shares. `progress` is called on the upload phase.
    func send(
        _ transfer: FileTransfer,
        to token: String,
        folder: String,
        referenceID: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> String {
        let data: Data
        do {
            data = try Data(contentsOf: transfer.fileURL)
        } catch {
            throw .unexpectedResponse("Couldn’t read \(transfer.fileName)")
        }

        let remotePath = try await upload(data, fileName: transfer.fileName, folder: folder, progress: progress)
        try await share(
            path: remotePath,
            token: token,
            caption: transfer.caption,
            replyTo: transfer.replyToMessageID,
            referenceID: referenceID
        )
        return remotePath
    }

    // MARK: - WebDAV

    /// Uploads, without ever silently overwriting: `If-None-Match: *` makes the PUT
    /// conditional on the name being free, and a clash gets a numbered name instead.
    func upload(
        _ data: Data,
        fileName: String,
        folder: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> String {
        let folder = folder.isEmpty ? Self.defaultFolder : folder

        for attempt in 0..<Self.maximumNameAttempts {
            let candidate = Self.name(fileName, attempt: attempt)
            let path = "\(folder)/\(candidate)"

            var headers: HTTPHeaders = [
                "Content-Type": "application/octet-stream",
                "Authorization": credentials.authorizationHeaderValue,
                // Create the folder if it isn't there yet, rather than a separate MKCOL.
                "X-NC-WebDAV-Auto-Mkcol": "1",
                // Only create; never replace someone's existing file.
                "If-None-Match": "*"
            ]
            headers["OC-Total-Length"] = String(data.count)

            let request = HTTPRequest(
                method: .put,
                url: server.url(path: Endpoint.webDAV(userID: userID, path: path)),
                headers: headers,
                body: data,
                // Big files need a long leash.
                timeout: 600
            )

            let response = try await transport.upload(request, progress: progress)
            switch response.status {
            case 200...299:
                Log.chat.info("Uploaded an attachment to \(folder)")
                return path
            case 412, 405:
                // Taken — try the next name.
                continue
            case 507:
                throw .serverError(status: 507, message: "Not enough space in your Nextcloud")
            default:
                throw TalkError.from(status: response.status, headers: response.headers)
            }
        }

        throw .conflict(message: "Couldn’t find a free name for \(fileName)")
    }

    private static let maximumNameAttempts = 20

    /// `report.pdf`, then `report (2).pdf`, `report (3).pdf`… the way Finder does it.
    static func name(_ fileName: String, attempt: Int) -> String {
        guard attempt > 0 else { return fileName }
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let numbered = "\(base) (\(attempt + 1))"
        return ext.isEmpty ? numbered : "\(numbered).\(ext)"
    }

    // MARK: - Sharing into the conversation

    /// `shareType: 10` is a Talk conversation; `shareWith` is its token.
    func share(
        path: String,
        token: String,
        caption: String = "",
        replyTo: Int? = nil,
        referenceID: String? = nil
    ) async throws(TalkError) {
        var metadata: [String: Any] = ["messageType": "comment"]
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { metadata["caption"] = caption }
        if let replyTo, replyTo > 0 { metadata["replyTo"] = replyTo }

        var form: [String: String] = [
            "shareType": "10",
            "shareWith": token,
            "path": path
        ]
        if let referenceID { form["referenceId"] = referenceID }
        if let encoded = try? JSONSerialization.data(withJSONObject: metadata),
           let json = String(data: encoded, encoding: .utf8) {
            form["talkMetaData"] = json
        }

        _ = try await client.send(OCSRequest.post(Endpoint.shares, form: form), as: EmptyResponse.self)
    }
}
