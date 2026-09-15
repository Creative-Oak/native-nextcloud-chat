import AppKit
import Foundation
import Observation

/// Files staged in the composer, and on their way into the open conversation.
///
/// Attaching a file starts its upload straight away — the bytes go up while you type, so
/// sending is quick — but the upload stops one step short of the conversation. A staged
/// file sits at `.uploaded` until the send button says otherwise, which is what lets a
/// photo and the sentence about it arrive as one message.
///
/// Uploads run one at a time rather than all at once: a dozen parallel PUTs to the same
/// Nextcloud is a good way to get rate-limited, and a queue also makes the progress
/// readable.
@MainActor
@Observable
final class AttachmentQueue {
    private(set) var transfers: [FileTransfer] = []
    private(set) var isDropTargeted = false

    private let session: Session
    /// Nil in a draft: uploading needs no conversation, only sharing does, so files can go
    /// up while you are still deciding who to send them to. Set once the conversation exists
    /// — see ``adopt(token:)``.
    private var token: String?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// The transfers the send button has committed. Everything else is still just staged,
    /// however far up it has got.
    @ObservationIgnored private var committed: Set<UUID> = []

    init(session: Session, token: String? = nil) {
        self.session = session
        self.token = token
        Self.sweepAbandonedScratchFiles()
    }

    /// Anything staged or in flight — what makes the send button worth pressing with an
    /// empty field.
    var hasStaged: Bool {
        transfers.contains { !$0.state.isFinished }
    }

    var canAttach: Bool {
        session.capabilitySnapshot.attachmentsAllowed
    }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
    }

    /// Hands the queue the conversation its files belong in, once there is one.
    ///
    /// Anything committed before this was waiting on exactly that, so the pump is asked to
    /// look again.
    func adopt(token: String) {
        guard self.token == nil else { return }
        self.token = token
        start()
    }

    // MARK: - Staging

    /// Files dragged in from Finder, picked from the open panel, or chosen in Photos.
    ///
    /// No caption and no reply here: both belong to the message, and the message is not
    /// written yet. They are read off the composer when send is pressed.
    func enqueue(urls: [URL]) {
        stage(urls) { _ in nil }
    }

    /// Photos and videos copied out of the picker on their way here, each into a scratch
    /// directory of its own — see ``PickedPhoto``.
    ///
    /// Separate from ``enqueue(urls:)`` because these are the app's own files rather than
    /// the user's, which is what decides whether they may be deleted afterwards.
    func enqueue(scratchFiles urls: [URL]) {
        stage(urls) { $0.deletingLastPathComponent() }
    }

    /// An image pasted from the clipboard — written to a temporary file first, because the
    /// upload path takes a file, and named after the moment it was pasted so it doesn't
    /// arrive as "image.png" for the fiftieth time.
    func enqueuePastedImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        let name = "Pasted image \(Self.timestampFormatter.string(from: .now)).png"
        do {
            // Its own scratch directory, like a picked photo: the name carries a timestamp
            // only to the second, so two quick pastes would otherwise collide, and a
            // directory of the app's own is what makes the file safe to delete later.
            let directory = try AttachmentScratch.makeItemDirectory()
            let url = directory.appending(path: name)
            try png.write(to: url)
            stage([url]) { _ in directory }
        } catch {
            Log.chat.warning("Couldn’t stage a pasted image for upload")
        }
    }

    /// - Parameter temporaryItem: what the app made for this URL and must clear away again,
    ///   or nil when the file is the user's own.
    private func stage(_ urls: [URL], temporaryItem: (URL) -> URL?) {
        for url in urls {
            guard var transfer = Self.makeTransfer(for: url) else {
                // Refused, so no transfer will ever clean up after it — do it here instead.
                if let item = temporaryItem(url) { Self.discard(item) }
                continue
            }
            transfer.temporaryItem = temporaryItem(url)
            transfers.append(transfer)
        }
        start()
    }

    // MARK: - Sending

    /// Commits everything staged: the words become the caption on the first of them, and
    /// each shares itself into the conversation as its upload lands.
    ///
    /// A caption belongs to one share, so it goes on the first file and the rest arrive
    /// bare — see `docs/plans/2026-09-15-attachments-photos-polls-design.md` § 1.
    func send(caption: String, replyTo: Int?) {
        committed.formUnion(FileTransfer.apply(caption: caption, replyTo: replyTo, to: &transfers))
        start()
    }

    func retry(_ transfer: FileTransfer) {
        guard let index = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
        // Where it failed decides where it resumes: with a remote path the bytes are already
        // up and only the share went wrong, and re-uploading would leave a second copy in
        // the user's Files.
        transfers[index].state = transfers[index].remotePath == nil ? .queued : .uploaded
        start()
    }

    /// Takes a file back out of the composer, and out of the user's Nextcloud with it.
    func remove(_ transfer: FileTransfer) {
        committed.remove(transfer.id)
        transfers.removeAll { $0.id == transfer.id }
        // Out of the tray is the last anyone will see of it, including a transfer that
        // failed and was never retried — so whatever the app made for it goes now.
        if let temporaryItem = transfer.temporaryItem { Self.discard(temporaryItem) }
        if let path = transfer.remotePath {
            deleteRemote(path: path, name: transfer.fileName)
        }
        // A file removed mid-upload is dealt with when that upload lands: the PUT is already
        // in flight and there is no way to unsend it, so `drainOnce` notices the row has
        // gone and deletes what arrived.
    }

    func clearFinished() {
        for transfer in transfers where transfer.state == .completed {
            if let temporaryItem = transfer.temporaryItem { Self.discard(temporaryItem) }
        }
        transfers.removeAll { $0.state == .completed }
    }

    // MARK: - The queue

    /// The next piece of work, in the order things were staged — so a caption on the first
    /// file is shared before the files that follow it.
    private enum Step { case upload, share }

    private func nextStep() -> (index: Int, step: Step)? {
        for (index, transfer) in transfers.enumerated() {
            switch transfer.state {
            case .queued:
                return (index, .upload)
            case .uploaded where committed.contains(transfer.id) && token != nil:
                return (index, .share)
            default:
                continue
            }
        }
        return nil
    }

    private func start() {
        guard pump == nil, nextStep() != nil else { return }
        pump = Task { [weak self] in
            await self?.drain()
            self?.pump = nil
            // A file staged between the drain's last look and the pump being cleared saw a
            // live pump and did nothing, and would then sit there with nothing left to run
            // it. Asking again once the pump is gone closes that window; with no work this
            // returns immediately.
            self?.start()
        }
    }

    private func drain() async {
        // Repeats rather than running once: files staged while the queue was tidying up
        // would otherwise sit there forever, because `start()` sees a live pump and returns
        // without doing anything.
        repeat {
            await drainOnce()
            try? await Task.sleep(for: .seconds(2))
            clearFinished()
        } while nextStep() != nil
    }

    private func drainOnce() async {
        while let (index, step) = nextStep() {
            let transfer = transfers[index]
            switch step {
            case .upload: await upload(transfer)
            case .share: await share(transfer)
            }
        }
    }

    private func upload(_ transfer: FileTransfer) async {
        update(transfer.id) { $0.state = .uploading(0) }
        let folder = session.capabilitySnapshot.config.attachmentsFolder ?? AttachmentService.defaultFolder

        do {
            let path = try await session.attachments.upload(
                transfer,
                folder: folder,
                progress: { [weak self] fraction in
                    Task { @MainActor in self?.report(fraction, for: transfer.id) }
                }
            )

            // The bytes are up, so a scratch copy the app made for this has done its job.
            // Only ever one of ours: a file the user chose has no `temporaryItem` and stays
            // exactly where they keep it.
            if let temporaryItem = transfer.temporaryItem {
                Self.discard(temporaryItem)
                update(transfer.id) { $0.temporaryItem = nil }
            }

            guard transfers.contains(where: { $0.id == transfer.id }) else {
                // Unstaged while its bytes were still going up. Take them back down.
                deleteRemote(path: path, name: transfer.fileName)
                return
            }
            update(transfer.id) {
                $0.remotePath = path
                $0.state = .uploaded
            }
        } catch {
            update(transfer.id) { $0.state = .failed(error.userMessage) }
            Log.chat.warning("Attachment upload failed: \(error.userMessage)")
        }
    }

    private func share(_ transfer: FileTransfer) async {
        guard let token, let path = transfer.remotePath else {
            update(transfer.id) { $0.state = .queued }
            return
        }
        update(transfer.id) { $0.state = .sharing }

        let reference = session.capabilitySnapshot.supportsReferenceIDs ? ReferenceID.generate() : nil
        do {
            try await session.attachments.share(
                path: path,
                token: token,
                caption: transfer.caption,
                replyTo: transfer.replyToMessageID,
                referenceID: reference
            )
            update(transfer.id) { $0.state = .completed }
        } catch {
            update(transfer.id) { $0.state = .failed(error.userMessage) }
            Log.chat.warning("Attachment share failed: \(error.userMessage)")
        }
    }

    /// Best effort. A file left behind here is a stray in the user's Nextcloud, which is
    /// better than an attachment they cannot get out of the tray.
    private func deleteRemote(path: String, name: String) {
        let attachments = session.attachments
        Task {
            // Typed, or the `Task` widens it to `any Error` and the message is lost.
            do throws(TalkError) {
                try await attachments.delete(path: path)
            } catch {
                Log.chat.warning("Couldn’t remove \(name) after it was unstaged: \(error.userMessage)")
            }
        }
    }

    private func report(_ fraction: Double, for id: UUID) {
        update(id) { transfer in
            // Only while it really is uploading: a late callback must not undo `.uploaded`.
            if case .uploading = transfer.state { transfer.state = .uploading(min(fraction, 1)) }
        }
    }

    private func update(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private static func makeTransfer(for url: URL) -> FileTransfer? {
        // The door. `.dropDestination(for: URL.self)` matches `public.url`, not just
        // `public.file-url`, so a hyperlink dragged out of the transcript or a browser
        // arrives here looking exactly like a dragged document — and the upload path reads
        // whatever URL it is given, which would make the app fetch that link from inside
        // the user's network and post the answer into their Nextcloud. Only local files.
        guard url.isLocalFile else { return nil }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        // Folders would need a recursive upload; that is not what dragging a folder into a
        // chat usually means, so it's refused rather than half-done.
        if values?.isDirectory == true { return nil }
        return FileTransfer(fileURL: url, byteCount: values?.fileSize ?? 0)
    }

    // MARK: - The app's own temporary files

    /// Deletes something the app made for a transfer.
    ///
    /// Belt and braces on top of ``FileTransfer/temporaryItem``: whatever a transfer claims,
    /// nothing outside the app's own scratch directory is ever removed. The containment test
    /// is by path component on resolved paths, because the string prefix this replaced said
    /// yes to any sibling directory whose name merely started the same way.
    private static func discard(_ item: URL) {
        guard item.isContained(in: AttachmentScratch.directory) else { return }
        try? FileManager.default.removeItem(at: item)
    }

    /// Clears out anything a previous run left behind in the scratch directory.
    ///
    /// A transfer cleans up after itself when it finishes or leaves the tray, but a quit
    /// with files still staged skips both, and without this the directory keeps every photo
    /// and video the user ever tried to send, at full size. Only the app's own files live
    /// there, and an upload is given up on after ten minutes, so anything from yesterday
    /// belongs to a run that is over.
    private static func sweepAbandonedScratchFiles() {
        guard !hasSwept else { return }
        hasSwept = true

        let directory = AttachmentScratch.directory
        let abandonedAfter = Self.abandonedAfter
        Task.detached(priority: .background) {
            let manager = FileManager.default
            guard let items = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }

            for item in items {
                let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                guard let modified, Date.now.timeIntervalSince(modified) > abandonedAfter else { continue }
                try? manager.removeItem(at: item)
            }
        }
    }

    /// Once per launch is enough — there is a queue per conversation and one for drafts.
    private static var hasSwept = false
    private static let abandonedAfter: TimeInterval = 24 * 60 * 60

    /// Fixed format, so fixed locale: left to the user's own, this same pattern writes
    /// 2568 on a Buddhist calendar and Arabic-Indic digits in some locales — into a file
    /// name, which is the one place a date should be plain and sortable.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

/// Where the app puts files it makes for an upload: a pasted image, or a photo copied out of
/// the picker.
///
/// Its own directory under the temporary one, so what the app made is told from what the user
/// chose by a fact rather than by a guess. People are handed real files out of the temporary
/// directory constantly — an attachment opened from Mail, a file dragged out of an archive
/// Archive Utility expanded — and attaching one of those must not delete their original.
enum AttachmentScratch {
    static let directory = URL.temporaryDirectory
        .appending(path: "app.kvidr.mac/Attachments", directoryHint: .isDirectory)

    /// A fresh directory for one file, since two picks or two pastes can share a name.
    static func makeItemDirectory() throws -> URL {
        let url = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
