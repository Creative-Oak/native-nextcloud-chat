// Stand-in for LinkPresentation: only the surface the app uses. See run.sh.
import AppKit
import Foundation

public final class LPLinkMetadata: NSObject {
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
