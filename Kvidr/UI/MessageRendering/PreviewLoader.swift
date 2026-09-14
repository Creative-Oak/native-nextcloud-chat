import AppKit
import SwiftUI

/// Thumbnails for files shared into a conversation.
///
/// Same shape as ``AvatarLoader`` and for the same reason: `NSImage` isn't `Sendable`, so
/// the cache lives on the main actor while the fetching happens inside an actor.
@MainActor
final class PreviewLoader {
    private let session: Session
    private var memory: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Files the server has no preview for. Remembered so we ask exactly once.
    private var unavailable: Set<String> = []

    private let memoryLimit = 120

    init(session: Session) {
        self.session = session
    }

    func cached(fileID: String, width: Int) -> NSImage? {
        memory[key(fileID, width)]
    }

    func hasNoPreview(fileID: String) -> Bool {
        unavailable.contains(fileID)
    }

    func preview(fileID: String, width: Int, height: Int) async -> NSImage? {
        let key = key(fileID, width)
        if let cached = memory[key] { return cached }
        if unavailable.contains(fileID) { return nil }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            do throws(TalkError) {
                let data = try await self.session.attachments.preview(fileID: fileID, width: width, height: height)
                guard let image = NSImage(data: data) else {
                    self.unavailable.insert(fileID)
                    return nil
                }
                self.store(image, for: key)
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

    private func store(_ image: NSImage, for key: String) {
        if memory.count >= memoryLimit { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
    }

    private func key(_ fileID: String, _ width: Int) -> String { "\(fileID)@\(width)" }
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
struct InlineImageView: View {
    let object: RichObject
    var maximumWidth: CGFloat = 320

    @Environment(\.previewLoader) private var loader
    @Environment(\.openAttachment) private var openAttachment
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maximumWidth, maxHeight: 280)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    }
                    .contentShape(.rect)
                    .onTapGesture { openAttachment?(object) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(object.name)
                    .help(object.name)
            } else if didFail {
                EmptyView()
            } else {
                placeholder
            }
        }
        .task(id: object.id) { await load() }
    }

    /// Sized from the file's own dimensions where the server sent them, so the layout
    /// doesn't jump when the picture arrives.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary.opacity(0.4))
            .frame(width: placeholderSize.width, height: placeholderSize.height)
            .overlay { ProgressView().controlSize(.small) }
    }

    private var placeholderSize: CGSize {
        guard let width = object.width, let height = object.height, width > 0, height > 0 else {
            return CGSize(width: 220, height: 150)
        }
        let scale = min(maximumWidth / CGFloat(width), 280 / CGFloat(height), 1)
        return CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    }

    private func load() async {
        guard let loader, object.previewAvailable else {
            didFail = true
            return
        }
        if let cached = loader.cached(fileID: object.id, width: 640) {
            image = cached
            return
        }
        let fetched = await loader.preview(fileID: object.id, width: 640, height: 640)
        withAnimation(.easeOut(duration: 0.2)) {
            image = fetched
            didFail = fetched == nil
        }
    }
}
