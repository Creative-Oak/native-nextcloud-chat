import Foundation

/// One file on its way into a conversation.
struct FileTransfer: Sendable, Identifiable, Equatable {
    enum State: Sendable, Equatable {
        case queued
        /// 0…1 of the bytes sent.
        case uploading(Double)
        /// In the user's Nextcloud, and staged in the composer: everything is done except
        /// putting it in the conversation, which waits for the send button.
        case uploaded
        /// Being shared into the conversation.
        case sharing
        case completed
        case failed(String)

        /// Staged and waiting for you, rather than on its way anywhere.
        var isStaged: Bool {
            if case .uploaded = self { return true } else { return false }
        }

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
            case .uploaded: 0.9
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
    /// Sent with the file so it arrives as one message with a caption. Filled in when the
    /// message is sent, not when the file is attached: which file carries the words depends
    /// on what else is staged beside it.
    var caption: String = ""
    var replyToMessageID: Int?
    /// Where the upload put it, once it has been uploaded. The share step needs this, and
    /// so does taking the file back out of the composer.
    var remotePath: String?
    /// Set only when the app wrote this file itself — a pasted image, or the copy made on
    /// the way out of the Photos picker — and naming the directory it was written into.
    ///
    /// Nil for a file the user chose, which is theirs and is never touched. Ownership is
    /// recorded rather than guessed at from the path: people are handed real files out of
    /// the temporary directory all the time (an attachment opened from Mail, a file dragged
    /// out of an archive), and a cleanup that goes by where a file happens to live deletes
    /// the original the moment one of those is attached.
    var temporaryItem: URL?

    init(fileURL: URL, byteCount: Int, caption: String = "", replyToMessageID: Int? = nil) {
        self.id = UUID()
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.byteCount = byteCount
        self.caption = caption
        self.replyToMessageID = replyToMessageID
    }
}

extension FileTransfer {
    /// Applies the message being sent to a batch of staged files, and answers which of them
    /// were committed.
    ///
    /// A caption belongs to one share, so the first file still on its way carries the words
    /// and the rest arrive bare — three photos and a sentence is three messages, not three
    /// copies of the sentence. Files that have already finished are left alone: they belong
    /// to a message that has been sent.
    static func apply(
        caption: String,
        replyTo: Int?,
        to transfers: inout [FileTransfer]
    ) -> Set<UUID> {
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var committed: Set<UUID> = []
        for index in transfers.indices where !transfers[index].state.isFinished {
            if committed.isEmpty { transfers[index].caption = caption }
            transfers[index].replyToMessageID = replyTo
            committed.insert(transfers[index].id)
        }
        return committed
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

    /// Uploads a staged file and answers where it landed.
    ///
    /// Putting it *into* a conversation is `share(path:token:…)`, a separate step taken when
    /// the message is actually sent — the two used to run back to back, which is what made a
    /// dropped file send itself before anyone could type a word beside it.
    func upload(
        _ transfer: FileTransfer,
        folder: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> String {
        // The guard is what makes the read below safe, so it sits directly on top of it.
        // `Data(contentsOf:)` reads whatever kind of URL it is handed: given `https://…` it
        // performs a blocking, untimed, unbounded GET on this actor and answers with the
        // body — which would then be uploaded to the user’s Nextcloud and shared into a
        // conversation. Given a named pipe it blocks on this actor until the app is quit.
        // Staging refuses both too, but a second place to stage from is one edit away, and
        // the read is here.
        guard transfer.fileURL.isAttachableFile else {
            throw .unexpectedResponse("Only files on this Mac can be attached")
        }

        let data: Data
        do {
            data = try Data(contentsOf: transfer.fileURL)
        } catch {
            throw .unexpectedResponse("Couldn’t read \(transfer.fileName)")
        }
        return try await upload(data, fileName: transfer.fileName, folder: folder, progress: progress)
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
            // One string, written once and then shared under that same name. The PUT below
            // goes to exactly this path and exactly this path is what comes back for
            // `share(path:)`. They used to be allowed to differ — the URL got the safe
            // spelling of the name and the caller got the raw one — so `Invoice #42.pdf`
            // went up as `Invoice _42.pdf`, the share asked for a file the server had never
            // written, and the send failed with the upload left behind in the user's Files.
            let path = Endpoint.filePath("\(folder)/\(candidate)")

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

    /// Removes a file from the user's Nextcloud.
    ///
    /// For a staged attachment taken back out of the composer: the bytes went up the moment
    /// it was attached, so removing the row has to remove them too, or thinking better of a
    /// file leaves it in the user's Files for good.
    func delete(path: String) async throws(TalkError) {
        let request = HTTPRequest(
            method: .delete,
            url: server.url(path: Endpoint.webDAV(userID: userID, path: path)),
            headers: ["Authorization": credentials.authorizationHeaderValue],
            body: nil,
            timeout: 60
        )
        let response = try await transport.send(request)
        // 404 counts: the file isn't there, which is what was asked for.
        guard (200...299).contains(response.status) || response.status == 404 else {
            throw TalkError.from(status: response.status, headers: response.headers)
        }
    }
}

// MARK: - Reading files back

extension AttachmentService {
    /// A thumbnail for a shared file, from Nextcloud's own preview service.
    ///
    /// `forceIcon=0` means the server returns 404 rather than a generic document icon when
    /// it can't render a preview — so the UI can show its own symbol instead of a picture
    /// of a symbol.
    func preview(fileID: String, width: Int, height: Int) async throws(TalkError) -> Data {
        // Not an OCS call: the preview service is a plain route that answers with an image.
        let request = HTTPRequest(
            method: .get,
            url: server.url(
                path: "/index.php/core/preview",
                query: [
                    URLQueryItem(name: "fileId", value: fileID),
                    URLQueryItem(name: "x", value: String(width)),
                    URLQueryItem(name: "y", value: String(height)),
                    URLQueryItem(name: "a", value: "1"),
                    URLQueryItem(name: "forceIcon", value: "0"),
                    URLQueryItem(name: "mode", value: "cover")
                ]
            ),
            headers: ["Authorization": credentials.authorizationHeaderValue],
            body: nil,
            timeout: 30
        )
        let response = try await transport.send(request)
        guard (200...299).contains(response.status) else {
            throw TalkError.from(status: response.status, headers: response.headers)
        }
        return response.body
    }

    /// Downloads a file from the user's Nextcloud over WebDAV.
    func download(path: String) async throws(TalkError) -> Data {
        let request = HTTPRequest(
            method: .get,
            url: server.url(path: Endpoint.webDAV(userID: userID, path: path)),
            headers: ["Authorization": credentials.authorizationHeaderValue],
            body: nil,
            timeout: 300
        )
        let response = try await transport.send(request)
        guard (200...299).contains(response.status) else {
            throw TalkError.from(status: response.status, headers: response.headers)
        }
        return response.body
    }

    /// Downloads by the file's numeric id, which is what a chat message carries. Uses the
    /// preview service at full size for images and WebDAV for anything else.
    func downloadSharedFile(_ object: RichObject) async throws(TalkError) -> Data {
        if let path = object.path, !path.isEmpty {
            return try await download(path: path)
        }
        throw .unexpectedResponse("That file has no path to download from")
    }
}

// MARK: - The questions the upload path asks about a URL

extension URL {
    /// A file on this Mac — not merely something spelled like one.
    ///
    /// A drop and a paste both arrive as a plain `URL`, and `public.url` matches a hyperlink
    /// as readily as a file, so by the time the composer sees one there is nothing left to
    /// tell a dragged web link from a dragged document except this.
    var isLocalFile: Bool {
        guard isFileURL else { return false }
        // `file://somewhere.example/share/secrets` is a file URL as well, and names another
        // machine’s disk rather than this one’s.
        guard let host = host(), !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    /// A file this app may actually read: spelled like a local file, *and* a regular file
    /// when asked.
    ///
    /// ``isLocalFile`` only reads the URL. That is enough to keep a hyperlink out, and not
    /// enough to keep out the things a path can name besides a document. A named pipe is the
    /// one that matters: `Data(contentsOf:)` on a FIFO nobody ever writes to blocks inside
    /// the `AttachmentService` actor and never returns, so every later upload, share, delete
    /// and preview in that session waits behind it forever — one dragged path, and the rest
    /// of the app's file handling is gone until it is quit. A character device is the same
    /// read with a different ending: `/dev/zero` answers, and keeps answering.
    ///
    /// Regular files only, therefore, which also subsumes the directory check staging used
    /// to make on its own.
    ///
    /// What this deliberately does *not* refuse is a file on a mounted volume. `/Volumes/…`
    /// on an SMB or NFS share is another machine's disk reached through a path, and reading
    /// it is a network fetch with this process's latency at the other end's mercy — but the
    /// user mounted it and the user picked the file, and refusing to attach from a work share
    /// would break something people legitimately do all day. The residual risk is a stall
    /// rather than a disclosure: a wedged mount hangs this actor exactly as a FIFO would, and
    /// the only real answer to that is to stream the upload from the file URL under a
    /// timeout, which is a change to the transport rather than to this predicate.
    var isAttachableFile: Bool {
        guard isLocalFile else { return false }
        let values = try? resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    /// Whether this URL names something inside `directory`.
    ///
    /// Compared component by component, on standardised and symlink-resolved paths. A string
    /// prefix is the tempting version and the wrong one: `/tmp/scratchX` has `/tmp/scratch`
    /// as a prefix, so a cleanup written that way reaches into the directory next door — and
    /// a path carrying `..` prefixes whatever you like while pointing somewhere else.
    func isContained(in directory: URL) -> Bool {
        guard isFileURL, directory.isFileURL else { return false }
        let container = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidate = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        // Strictly inside: a directory does not contain itself, and deleting the container is
        // never what a per-item cleanup meant.
        guard candidate.count > container.count else { return false }
        return Array(candidate.prefix(container.count)) == container
    }
}
