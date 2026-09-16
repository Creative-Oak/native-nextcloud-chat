import AppKit
import SwiftUI

/// Thumbnails for files shared into a conversation.
///
/// Same shape as ``AvatarLoader`` and for the same reason: `NSImage` isn't `Sendable`, so
/// the cache lives on the main actor while the fetching happens inside an actor.
///
/// The inline previews are also kept on disk, sealed with the account's key — see
/// ``EncryptedFileCache``. A picture seen once then draws at once the next time, and a
/// transcript full of photos isn't downloaded again every launch. The lightbox's full-size
/// image is not kept: it is large, and opened far less often than it is scrolled past.
@MainActor
final class PreviewLoader {
    private let session: Session
    private var memory: [String: NSImage] = [:]
    /// Each image's upright pixel size, by file — what ``ImageLayout`` needs, and what
    /// `NSImage.size` (in points) doesn't give.
    private var pixelSizes: [String: CGSize] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Files the server has no preview for. Remembered so we ask exactly once.
    private var unavailable: Set<String> = []
    private let disk: EncryptedFileCache

    private let memoryLimit = 120
    /// A few thousand previews at the size the transcript asks for.
    private static let diskBudget = 200 * 1024 * 1024
    /// The size the transcript shows a shared picture at, and the one kept on disk.
    static let inlineSize = 640

    init(session: Session, keyring: any CacheKeyring) {
        self.session = session
        let directory = URL.cachesDirectory
            .appending(path: "app.kvidr.mac/Previews", directoryHint: .isDirectory)
            .appending(path: CacheKey.fileName(session.account.id), directoryHint: .isDirectory)
        disk = EncryptedFileCache(
            directory: directory,
            sealer: CacheSealer(keyring: keyring, accountID: session.account.id, kind: .preview),
            byteBudget: Self.diskBudget
        )
    }

    func cached(fileID: String, width: Int) -> NSImage? {
        memory[key(fileID, width)]
    }

    func pixelSize(fileID: String) -> CGSize? {
        pixelSizes[fileID]
    }

    func hasNoPreview(fileID: String) -> Bool {
        unavailable.contains(fileID)
    }

    func preview(fileID: String, width: Int, height: Int) async -> NSImage? {
        let key = key(fileID, width)
        if let cached = memory[key] { return cached }
        if unavailable.contains(fileID) { return nil }
        if let existing = inFlight[key] { return await existing.value }

        let keepsOnDisk = width == Self.inlineSize
        let disk = disk
        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            if keepsOnDisk, let data = await disk.read(key), let image = self.accept(data, fileID: fileID, key: key) {
                return image
            }
            do throws(TalkError) {
                let data = try await self.session.attachments.preview(fileID: fileID, width: width, height: height)
                guard let image = self.accept(data, fileID: fileID, key: key) else {
                    self.unavailable.insert(fileID)
                    return nil
                }
                // Not after a purge: a fetch still in flight when the account signed out
                // must not put back what the purge has just cleared away.
                if keepsOnDisk, !Task.isCancelled { await disk.write(data, name: key) }
                return image
            } catch {
                // 404 here means "no preview for this kind of file", which is a normal
                // answer and worth remembering. A timeout or a dropped connection is not:
                // remembering those meant one bad moment cost every thumbnail of that file
                // for the rest of the session, with nothing short of a relaunch to undo it.
                if !error.isRetryable { self.unavailable.insert(fileID) }
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    /// Full-size, for the lightbox.
    func fullSize(fileID: String) async -> NSImage? {
        await preview(fileID: fileID, width: 1600, height: 1600)
    }

    /// Everything, memory and disk. For sign-out — though by then the account's key is gone
    /// and what is on disk can't be opened anyway.
    func purge() async {
        memory.removeAll()
        pixelSizes.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        await disk.purge()
    }

    private func accept(_ data: Data, fileID: String, key: String) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        if let pixels = ImageLayout.pixelSize(of: data) { pixelSizes[fileID] = pixels }
        store(image, for: key)
        return image
    }

    private func store(_ image: NSImage, for key: String) {
        if memory.count >= memoryLimit { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
    }

    /// Hex, so it is a safe file name as well as a memory key.
    private func key(_ fileID: String, _ width: Int) -> String {
        "\(CacheKey.fileName(fileID))-\(width)"
    }
}

private struct PreviewLoaderKey: EnvironmentKey {
    static let defaultValue: PreviewLoader? = nil
}

private struct OpenAttachmentKey: EnvironmentKey {
    // `@MainActor` rather than a bare function type: a bare one is not `Sendable`, which
    // a `static let` has to be under Swift 6. Every caller is a view anyway.
    static let defaultValue: (@MainActor (RichObject) -> Void)? = nil
}

extension EnvironmentValues {
    var previewLoader: PreviewLoader? {
        get { self[PreviewLoaderKey.self] }
        set { self[PreviewLoaderKey.self] = newValue }
    }

    /// Opens an attachment in the in-app viewer. Set by the chat view.
    var openAttachment: (@MainActor (RichObject) -> Void)? {
        get { self[OpenAttachmentKey.self] }
        set { self[OpenAttachmentKey.self] = newValue }
    }
}

/// An image shared into the conversation, shown inline.
///
/// Its frame is decided before the picture arrives and kept when it does — see
/// ``ImageLayout`` — so a picture loading doesn't move the transcript.
struct InlineImageView: View {
    let object: RichObject
    var limits: ImageLayout.Limits = .transcript
    /// Rounder than a thumbnail in a row, because with no bubble around it the picture is
    /// the shape the eye reads.
    var cornerRadius: CGFloat = 16

    @Environment(\.previewLoader) private var loader
    @Environment(\.openAttachment) private var openAttachment
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        let frame = frameSize
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.4))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // Filling the frame rather than fitting it: when the shapes agree, which
                    // is what the frame was chosen for, the difference is a rounding pixel.
                    .aspectRatio(contentMode: .fill)
                    .frame(width: frame.width, height: frame.height)
                    .transition(.opacity)
            } else if didFail {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
        .contentShape(.rect)
        .onTapGesture { openAttachment?(object) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(object.name)
        .help(object.name)
        .task(id: object.id) { await load() }
    }

    private var frameSize: CGSize {
        let announced: CGSize? = if let width = object.width, let height = object.height {
            CGSize(width: width, height: height)
        } else {
            nil
        }
        return ImageLayout.frame(announced: announced, original: loader?.pixelSize(fileID: object.id), limits: limits)
    }

    private func load() async {
        guard let loader, object.previewAvailable else {
            didFail = true
            return
        }
        let size = PreviewLoader.inlineSize
        if let cached = loader.cached(fileID: object.id, width: size) {
            image = cached
            return
        }
        let fetched = await loader.preview(fileID: object.id, width: size, height: size)
        withAnimation(.easeOut(duration: 0.2)) {
            image = fetched
            didFail = fetched == nil
        }
    }
}
