import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Files on their way into the open conversation.
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

    init(session: Session, token: String) {
        self.session = session
        self.token = token
    }

    var hasActiveTransfers: Bool {
        transfers.contains { !$0.state.isFinished }
    }

    var canAttach: Bool {
        session.capabilitySnapshot.attachmentsAllowed
    }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
    }

    // MARK: - Adding

    /// Files dragged in from Finder, or picked from the open panel.
    func enqueue(urls: [URL], caption: String = "", replyTo: Int? = nil) {
        for url in urls {
            guard let transfer = Self.makeTransfer(for: url, caption: caption, replyTo: replyTo) else { continue }
            transfers.append(transfer)
        }
        start()
    }

    /// An image pasted from the clipboard — written to a temporary file first, because the
    /// upload path takes a file, and named after the moment it was pasted so it doesn't
    /// arrive as "image.png" for the fiftieth time.
    func enqueuePastedImage(_ image: NSImage, caption: String = "", replyTo: Int? = nil) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        let name = "Pasted image \(Self.timestampFormatter.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try png.write(to: url)
        } catch {
            Log.chat.warning("Couldn’t stage a pasted image for upload")
            return
        }
        enqueue(urls: [url], caption: caption, replyTo: replyTo)
    }

    func retry(_ transfer: FileTransfer) {
        guard let index = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
        transfers[index].state = .queued
        start()
    }

    func remove(_ transfer: FileTransfer) {
        transfers.removeAll { $0.id == transfer.id }
    }

    func clearFinished() {
        transfers.removeAll { $0.state == .completed }
    }

    // MARK: - The queue

    private func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            await self?.drain()
            self?.pump = nil
        }
    }

    private func drain() async {
        while let index = transfers.firstIndex(where: { $0.state == .queued }) {
            let transfer = transfers[index]
            transfers[index].state = .uploading(0)

            let folder = session.capabilitySnapshot.config.attachmentsFolder ?? AttachmentService.defaultFolder
            let reference = session.capabilitySnapshot.supportsReferenceIDs ? ReferenceID.generate() : nil

            do {
                _ = try await session.attachments.send(
                    transfer,
                    to: token,
                    folder: folder,
                    referenceID: reference,
                    progress: { [weak self] fraction in
                        Task { @MainActor in self?.report(fraction, for: transfer.id) }
                    }
                )
                update(transfer.id) { $0.state = .completed }

                // Tidy up after a paste: the temporary file has done its job.
                if transfer.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    try? FileManager.default.removeItem(at: transfer.fileURL)
                }
            } catch {
                update(transfer.id) { $0.state = .failed(error.userMessage) }
                Log.chat.warning("Attachment failed: \(error.userMessage)")
            }
        }

        // Completed rows linger briefly so the user sees them finish, then clear themselves.
        try? await Task.sleep(for: .seconds(2))
        clearFinished()
    }

    private func report(_ fraction: Double, for id: UUID) {
        update(id) { transfer in
            // The share phase sets its own state; don't let a late progress callback undo it.
            if case .uploading = transfer.state { transfer.state = .uploading(fraction) }
            if fraction >= 1, case .uploading = transfer.state { transfer.state = .sharing }
        }
    }

    private func update(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private static func makeTransfer(for url: URL, caption: String, replyTo: Int?) -> FileTransfer? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        // Folders would need a recursive upload; that is not what dragging a folder into a
        // chat usually means, so it's refused rather than half-done.
        if values?.isDirectory == true { return nil }
        return FileTransfer(
            fileURL: url,
            byteCount: values?.fileSize ?? 0,
            caption: caption,
            replyToMessageID: replyTo
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}
