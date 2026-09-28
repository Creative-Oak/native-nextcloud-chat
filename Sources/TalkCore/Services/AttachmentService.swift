import Foundation
import UniformTypeIdentifiers

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
    /// The thread it is sent into, when it isn't a reply (a reply goes where its message is).
    var threadID: Int?
    /// Set on the file that starts a thread: the first, which carries the words too.
    var threadTitle: String?
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
        threadID: Int? = nil,
        threadTitle: String? = nil,
        to transfers: inout [FileTransfer]
    ) -> Set<UUID> {
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var committed: Set<UUID> = []
        for index in transfers.indices where !transfers[index].state.isFinished {
            if committed.isEmpty {
                transfers[index].caption = caption
                transfers[index].threadTitle = threadTitle
            }
            transfers[index].replyToMessageID = replyTo
            transfers[index].threadID = threadID
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
        // The guard is what makes the read safe, so it sits directly before it. Handed
        // `https://…`, a read would be a GET from inside the user's network whose answer is
        // then posted into a conversation; handed a named pipe, it never finishes. Staging
        // refuses both too, but a second place to stage from is one edit away, and the read
        // starts here.
        //
        // And nothing on this actor touches the file system. Even asking what the file is —
        // a `stat` — can block forever on a wedged network mount, and this actor is the one
        // every later upload, share, delete and preview goes through. So the question is
        // asked elsewhere, under a deadline, and the bytes are read by the transport as it
        // sends them.
        guard transfer.fileURL.isLocalFile else {
            throw .fileNotAttachable
        }
        let byteCount: Int?
        switch await FileInspection.inspect(transfer.fileURL) {
        case .regularFile(let size):
            byteCount = size
        case .notAttachable:
            throw .fileNotAttachable
        case .missing:
            throw .fileMissing
        case .notAnswering:
            throw .fileNotAnswering
        }
        // The file can still change between that answer and the read — replaced by a pipe,
        // or its mount wedging now rather than a moment ago. The transport reads it on a
        // thread of its own and gives up on a read that stops answering, so the worst that
        // costs is this one transfer.
        return try await upload(.file(transfer.fileURL), byteCount: byteCount, fileName: transfer.fileName, folder: folder, progress: progress)
    }

    // MARK: - WebDAV

    /// Uploads bytes already in memory. See ``upload(_:byteCount:fileName:folder:progress:)``.
    func upload(
        _ data: Data,
        fileName: String,
        folder: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(TalkError) -> String {
        try await upload(.data(data), byteCount: data.count, fileName: fileName, folder: folder, progress: progress)
    }

    private enum UploadBody {
        case data(Data)
        case file(URL)
    }

    /// Uploads, without ever silently overwriting: `If-None-Match: *` makes the PUT
    /// conditional on the name being free, and a clash gets a numbered name instead.
    private func upload(
        _ body: UploadBody,
        byteCount: Int?,
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
                // Nextcloud keeps the type it is told. Every upload used to say
                // `application/octet-stream`, so a WAV was stored as unknown bytes: no player
                // for a voice message, and no type-based handling for anything else either.
                "Content-Type": Self.mimeType(forFileName: candidate),
                "Authorization": credentials.authorizationHeaderValue,
                // Create the folder if it isn't there yet, rather than a separate MKCOL.
                "X-NC-WebDAV-Auto-Mkcol": "1",
                // Only create; never replace someone's existing file.
                "If-None-Match": "*"
            ]
            if let byteCount {
                headers["OC-Total-Length"] = String(byteCount)
                // A streamed body has no length of its own, and without one it goes out
                // chunked, which not every proxy in front of a Nextcloud accepts on a PUT.
                if case .file = body { headers["Content-Length"] = String(byteCount) }
            }

            var request = HTTPRequest(
                method: .put,
                url: server.url(path: Endpoint.webDAV(userID: userID, path: path)),
                headers: headers,
                // Big files need a long leash.
                timeout: 600
            )
            switch body {
            case .data(let data): request.body = data
            case .file(let url): request.bodyFile = url
            }

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

        throw .conflict(message: String(localized: "Couldn’t find a free name for \(fileName)", comment: "Upload failed: %@ is a file name"))
    }

    private static let maximumNameAttempts = 20

    /// The type a file's extension names, in Nextcloud's own words — falling back to plain
    /// bytes when the extension says nothing.
    ///
    /// Nextcloud's spelling matters, not just the type: Talk only keeps a voice message a
    /// voice message when the file is exactly `audio/wav` or `audio/mpeg`, and macOS calls a
    /// WAV `audio/vnd.wave`. Where the two disagree, Nextcloud's name wins.
    static func mimeType(forFileName name: String) -> String {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return "application/octet-stream" }
        if let nextcloud = nextcloudMimeTypes[fileExtension] { return nextcloud }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Every extension where Nextcloud's `mimetypemapping.dist.json` (server 34) names a type
    /// differently from macOS.
    private static let nextcloudMimeTypes: [String: String] = [
        "arw": "image/x-dcraw",
        "avi": "video/x-msvideo",
        "bin": "application/x-bin",
        "cr2": "image/x-dcraw",
        "dcr": "image/x-dcraw",
        "dng": "image/x-dcraw",
        "docm": "application/vnd.ms-word.document.macroEnabled.12",
        "dv": "video/dv",
        "emf": "image/emf",
        "erf": "image/x-dcraw",
        "exe": "application/x-ms-dos-executable",
        "gz": "application/gzip",
        "gzip": "application/gzip",
        "hif": "image/heic",
        "ico": "image/x-icon",
        "iiq": "image/x-dcraw",
        "js": "application/javascript",
        "m4a": "audio/mp4",
        "m4v": "video/mp4",
        "nef": "image/x-dcraw",
        "orf": "image/x-dcraw",
        "otf": "application/font-sfnt",
        "pef": "image/x-dcraw",
        "php": "application/x-php",
        "pl": "application/x-perl",
        "potm": "application/vnd.ms-powerpoint.template.macroEnabled.12",
        "ppsm": "application/vnd.ms-powerpoint.slideshow.macroEnabled.12",
        "pptm": "application/vnd.ms-powerpoint.presentation.macroEnabled.12",
        "psd": "application/x-photoshop",
        "py": "text/x-python",
        "raf": "image/x-dcraw",
        "rar": "application/x-rar-compressed",
        "rw2": "image/x-dcraw",
        "sr2": "image/x-dcraw",
        "srf": "image/x-dcraw",
        "tga": "image/tga",
        "ttf": "application/font-sfnt",
        "vsd": "application/vnd.visio",
        "vsdm": "application/vnd.ms-visio.drawing.macroEnabled.12",
        "vsdx": "application/vnd.ms-visio.drawing",
        "vssm": "application/vnd.ms-visio.stencil.macroEnabled.12",
        "vssx": "application/vnd.ms-visio.stencil",
        "vstm": "application/vnd.ms-visio.template.macroEnabled.12",
        "vstx": "application/vnd.ms-visio.template",
        "wav": "audio/wav",
        "xlam": "application/vnd.ms-excel.addin.macroEnabled.12",
        "xlsb": "application/vnd.ms-excel.sheet.binary.macroEnabled.12",
        "xlsm": "application/vnd.ms-excel.sheet.macroEnabled.12",
        "xltm": "application/vnd.ms-excel.template.macroEnabled.12",
        "yaml": "application/yaml",
        "yml": "application/yaml"
    ]

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
    ///
    /// - Parameter isVoiceMessage: shares the file as a voice message, which Talk's clients
    ///   draw as a player rather than as a file — the `messageType` is all that says so.
    func share(
        path: String,
        token: String,
        caption: String = "",
        replyTo: Int? = nil,
        referenceID: String? = nil,
        isVoiceMessage: Bool = false,
        threadID: Int? = nil,
        threadTitle: String? = nil
    ) async throws(TalkError) {
        var metadata: [String: Any] = ["messageType": isVoiceMessage ? "voice-message" : "comment"]
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { metadata["caption"] = caption }
        if let replyTo, replyTo > 0 {
            metadata["replyTo"] = replyTo
        } else if let threadID {
            metadata["threadId"] = threadID
        } else if let threadTitle, !threadTitle.isEmpty {
            metadata["threadTitle"] = threadTitle
        }

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
    /// rather than a disclosure, and it applies to this predicate too: on a wedged mount the
    /// `stat` below never returns. The upload path therefore asks through
    /// ``FileInspection``, off its actor and under a deadline, and streams the bytes rather
    /// than reading them itself.
    var isAttachableFile: Bool {
        guard isLocalFile else { return false }
        if let isRegularFile = (try? resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile {
            return isRegularFile
        }
        // Not every Foundation answers that key — this module builds on Linux too — and a
        // predicate that has to fail closed must not fail closed on everything. Asking the
        // file system for the item's type directly is the same question in older words.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvingSymlinksInPath().path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
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

// MARK: - Asking the file system, with a way out

/// What a file turned out to be, asked somewhere a hang can't reach the caller.
///
/// A `stat` on a network mount whose server has gone away blocks in the kernel, and nothing
/// in Swift concurrency can interrupt it. So the question goes to a GCD thread, and the
/// caller stops waiting at the deadline. The thread may stay stuck until the mount recovers
/// or is force-unmounted; that is the price, and it is one thread rather than the actor.
/// The cooperative pool is deliberately not used: it has a thread per core, and a few
/// stuck ones would starve the whole app.
enum FileInspection: Sendable, Equatable {
    /// Readable as an attachment. The size is `nil` when the file system wouldn't say.
    case regularFile(byteCount: Int?)
    /// Not a regular local file — a link, a directory, a pipe, a device, or nothing at all.
    case notAttachable
    /// Nothing at that path at all.
    case missing
    /// No answer before the deadline.
    case notAnswering

    /// A local disk answers in microseconds and a healthy share in milliseconds; ten
    /// seconds is well past both, and still short enough that a stuck upload says so.
    static let deadline: TimeInterval = 10

    static func inspect(
        _ url: URL,
        deadline: TimeInterval = FileInspection.deadline,
        probe: @escaping @Sendable (URL) -> FileInspection = FileInspection.probe
    ) async -> FileInspection {
        await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            DispatchQueue.global(qos: .userInitiated).async { answer.give(probe(url)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                answer.give(.notAnswering)
            }
        }
    }

    /// The blocking question itself.
    static func probe(_ url: URL) -> FileInspection {
        guard url.isAttachableFile else {
            // Asked only once the file has been refused, so the common case stays one `stat`.
            return FileManager.default.fileExists(atPath: url.path) ? .notAttachable : .missing
        }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            return .regularFile(byteCount: size)
        }
        // The same fallback ``URL/isAttachableFile`` makes, for a Foundation that doesn't
        // answer the resource key.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber
        return .regularFile(byteCount: size?.intValue)
    }

    /// Reads a small file whole — a profile picture — where a hang can't reach the caller.
    ///
    /// The same two steps an upload takes: ask what the file is under the deadline, then
    /// read it on a thread of its own under the deadline again, since the file can stop
    /// answering between the two.
    static func read(
        _ url: URL,
        maximumBytes: Int,
        deadline: TimeInterval = FileInspection.deadline
    ) async throws(TalkError) -> Data {
        guard url.isLocalFile else { throw .fileNotAttachable }
        switch await inspect(url, deadline: deadline) {
        case .regularFile(let size):
            if let size, size > maximumBytes { throw .fileTooLarge }
        case .notAttachable:
            throw .fileNotAttachable
        case .missing:
            throw .fileMissing
        case .notAnswering:
            throw .fileNotAnswering
        }

        let result: Result<Data, TalkError> = await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                if let data = try? Data(contentsOf: url) {
                    answer.give(.success(data))
                } else {
                    answer.give(.failure(FileManager.default.fileExists(atPath: url.path) ? .fileNotAnswering : .fileMissing))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                answer.give(.failure(.fileNotAnswering))
            }
        }
        let data = try result.get()
        // The size can change between the question and the read.
        guard data.count <= maximumBytes else { throw .fileTooLarge }
        return data
    }

    /// Resumes a continuation with whichever answer arrives first, and ignores the other.
    private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func give(_ result: Value) {
            let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: result)
        }
    }
}
