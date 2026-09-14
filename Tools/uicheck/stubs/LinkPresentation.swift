// Stand-in for LinkPresentation: only the surface the app uses. See run.sh.
import AppKit
import Foundation

/// Sendable, as the audited SDK header has it: the metadata object is a value-like
/// snapshot, which is what makes `try await provider.startFetchingMetadata(for:)` usable
/// from the main actor — the way every caller uses it.
public final class LPLinkMetadata: NSObject, @unchecked Sendable {
    public var title: String?
    public var originalURL: URL?
    public var url: URL?
    public var imageProvider: NSItemProvider?
    public override init() {}
}

public final class LPMetadataProvider: NSObject {
    public var timeout: TimeInterval = 30
    public override init() {}
    public func startFetchingMetadata(for url: URL) async throws -> LPLinkMetadata { LPLinkMetadata() }
}
