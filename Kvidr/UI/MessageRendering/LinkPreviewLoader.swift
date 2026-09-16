import AppKit
import LinkPresentation
import SwiftUI

/// What a link preview card shows: the page's title, its host, and its lead image if it
/// offers one.
struct LinkPreview: Sendable {
    var url: URL
    var title: String?
    var host: String
    /// `NSImage` isn't `Sendable`; the loader hands these out on the main actor only.
    nonisolated(unsafe) var image: NSImage?
}

/// Rich previews for links in messages, fetched with the system's own link presentation
/// machinery — the same one Messages uses, so a page previews here the way it previews
/// there.
///
/// Same shape as ``PreviewLoader`` and for the same reason: `NSImage` isn't `Sendable`,
/// so the cache lives on the main actor. Each page is asked about exactly once per run;
/// a page that has nothing to show is remembered as such rather than asked again.
@MainActor
final class LinkPreviewLoader {
    private var memory: [URL: LinkPreview] = [:]
    private var inFlight: [URL: Task<LinkPreview?, Never>] = [:]
    private var unavailable: Set<URL> = []

    private let memoryLimit = 200

    init() {}

    func cached(_ url: URL) -> LinkPreview? {
        memory[url]
    }

    func hasNoPreview(_ url: URL) -> Bool {
        unavailable.contains(url)
    }

    func preview(for url: URL) async -> LinkPreview? {
        // Nothing is fetched until this holds. A preview is an HTTP GET made from the
        // reader's machine, at appearance, to an address whoever wrote the message picked:
        // for a link into the reader's own network that request is a probe they can neither
        // see nor have asked for, and the card that comes back — or doesn't — is the
        // answer, reported to the sender. See ``Foundation/URL/isPreviewableWebLink``.
        guard url.isPreviewableWebLink else { return nil }
        if let cached = memory[url] { return cached }
        if unavailable.contains(url) { return nil }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<LinkPreview?, Never> { [weak self] in
            guard let self else { return nil }
            switch await Self.fetch(url) {
            case .preview(let preview):
                self.store(preview, for: url)
                return preview
            case .nothingToShow:
                self.unavailable.insert(url)
                return nil
            case .failed:
                // Not remembered: asking again later is the whole difference between a
                // page that genuinely has no card and one that happened to be asked while
                // the network was down.
                return nil
            }
        }
        inFlight[url] = task
        let preview = await task.value
        inFlight[url] = nil
        return preview
    }

    private func store(_ preview: LinkPreview, for url: URL) {
        if memory.count >= memoryLimit, let victim = memory.keys.first {
            memory.removeValue(forKey: victim)
        }
        memory[url] = preview
    }

    private enum Outcome {
        case preview(LinkPreview)
        /// The page answered, and has nothing worth a card. Worth remembering.
        case nothingToShow
        /// The fetch itself failed, which says nothing about the page.
        case failed
    }

    /// A title is the least a card needs. A page that gives none gets no card — better
    /// than a card that says only the host, which the link text already does.
    private static func fetch(_ url: URL) async -> Outcome {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let metadata: LPLinkMetadata
        do {
            metadata = try await provider.startFetchingMetadata(for: url)
        } catch {
            Log.ui.warning("Link preview failed for \(url.host() ?? url.absoluteString): \(error.localizedDescription)")
            return .failed
        }
        guard let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            Log.ui.notice("Link preview for \(url.host() ?? url.absoluteString) came back without a title")
            return .nothingToShow
        }

        let image = await loadImage(from: metadata.imageProvider)
        Log.ui.notice("Link preview for \(url.host() ?? url.absoluteString): “\(title)”, image \(image == nil ? "no" : "yes")")
        return .preview(
            LinkPreview(
                url: metadata.originalURL ?? url,
                title: title,
                host: (metadata.url ?? url).host() ?? url.absoluteString,
                image: image
            )
        )
    }

    private static func loadImage(from provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }
}

private struct LinkPreviewLoaderKey: EnvironmentKey {
    static let defaultValue: LinkPreviewLoader? = nil
}

extension EnvironmentValues {
    var linkPreviewLoader: LinkPreviewLoader? {
        get { self[LinkPreviewLoaderKey.self] }
        set { self[LinkPreviewLoaderKey.self] = newValue }
    }
}
