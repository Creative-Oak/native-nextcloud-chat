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
    var maximumHeight: CGFloat = 280
    /// Rounder than a thumbnail in a row, because with no bubble around it the picture is
    /// the shape the eye reads.
    var cornerRadius: CGFloat = 16

    @Environment(\.previewLoader) private var loader
    @Environment(\.openAttachment) private var openAttachment
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // An exact frame, not `maxWidth`/`maxHeight`: those leave the container
                    // at its limit with the picture fitted inside, and the rounded border
                    // below then draws a box around the picture instead of round it. Inside
                    // a bubble the gap was accent on accent and invisible; bare on the
                    // transcript it is the first thing you see.
                    .frame(width: size(of: image).width, height: size(of: image).height)
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
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary.opacity(0.4))
            .frame(width: placeholderSize.width, height: placeholderSize.height)
            .overlay { ProgressView().controlSize(.small) }
    }

    private var placeholderSize: CGSize {
        guard let width = object.width, let height = object.height, width > 0, height > 0 else {
            return CGSize(width: 220, height: 150)
        }
        return fitted(CGSize(width: CGFloat(width), height: CGFloat(height)))
    }

    /// The picture's own size, which is what the container should be. The server's `width`
    /// and `height` are a hint for the placeholder; once the bytes are here, the bytes know.
    private func size(of image: NSImage) -> CGSize {
        fitted(image.size)
    }

    /// Scaled down to fit the limits, never up: a small picture blown out to fill the width
    /// is worse than a small picture.
    private func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: 220, height: 150)
        }
        let scale = min(maximumWidth / size.width, maximumHeight / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
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
