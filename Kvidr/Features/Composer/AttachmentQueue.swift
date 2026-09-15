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
    private let token: String
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// The transfers the send button has committed. Everything else is still just staged,
    /// however far up it has got.
    @ObservationIgnored private var committed: Set<UUID> = []

    init(session: Session, token: String) {
        self.session = session
        self.token = token
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

    // MARK: - Staging

    /// Files dragged in from Finder, picked from the open panel, or chosen in Photos.
    ///
    /// No caption and no reply here: both belong to the message, and the message is not
    /// written yet. They are read off the composer when send is pressed.
    func enqueue(urls: [URL]) {
        for url in urls {
            guard let transfer = Self.makeTransfer(for: url) else { continue }
            transfers.append(transfer)
        }
        start()
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
        let url = URL.temporaryDirectory.appending(path: name)
        do {
            try png.write(to: url)
        } catch {
            Log.chat.warning("Couldn’t stage a pasted image for upload")
            return
        }
        enqueue(urls: [url])
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
        if let path = transfer.remotePath {
            deleteRemote(path: path, name: transfer.fileName)
        }
        // A file removed mid-upload is dealt with when that upload lands: the PUT is already
        // in flight and there is no way to unsend it, so `drainOnce` notices the row has
        // gone and deletes what arrived.
    }

    func clearFinished() {
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
            case .uploaded where committed.contains(transfer.id):
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

            // Tidy up after a paste: the temporary file has done its job.
            if transfer.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: transfer.fileURL)
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
        guard let path = transfer.remotePath else {
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
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        // Folders would need a recursive upload; that is not what dragging a folder into a
        // chat usually means, so it's refused rather than half-done.
        if values?.isDirectory == true { return nil }
        return FileTransfer(fileURL: url, byteCount: values?.fileSize ?? 0)
    }

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
