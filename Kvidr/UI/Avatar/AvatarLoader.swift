import AppKit
import Foundation

/// Fetches and caches avatars.
///
/// Main-actor by design rather than an actor: `NSImage` is not `Sendable`, so an image
/// returned from an actor could not legally cross back. Everything expensive — the network
/// request and the disk read — happens off the main actor inside the calls this makes; only
/// the small, cheap cache lives here.
///
/// Three rules: never block a row on a fetch, never fetch the same avatar twice at once,
/// and key the cache on the server's own version string so a changed avatar busts the cache
/// and an unchanged one never refetches.
@MainActor
final class AvatarLoader {
    enum Subject: Sendable, Hashable {
        case user(id: String)
        case conversation(token: String, version: String)
    }

    private let client: OCSClient
    private let supportsConversationAvatars: Bool

    private var memory: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let diskCache: AvatarDiskCache

    /// A few hundred small images is a couple of megabytes — well worth never refetching.
    private let memoryLimit = 300

    init(client: OCSClient, supportsConversationAvatars: Bool) {
        self.client = client
        self.supportsConversationAvatars = supportsConversationAvatars
        self.diskCache = AvatarDiskCache()
    }

    /// Already in memory? Use this from `body` — it never suspends, so the first frame can
    /// draw the real avatar instead of the fallback.
    func cachedImage(for subject: Subject, size: Int, dark: Bool) -> NSImage? {
        memory[cacheKey(subject, size: size, dark: dark)]
    }

    func image(for subject: Subject, size: Int, dark: Bool) async -> NSImage? {
        let key = cacheKey(subject, size: size, dark: dark)
        if let cached = memory[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.fetch(subject, size: size, dark: dark, key: key)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    private func fetch(_ subject: Subject, size: Int, dark: Bool, key: String) async -> NSImage? {
        if let data = await diskCache.read(key: key), let image = NSImage(data: data) {
            store(image, for: key)
            return image
        }

        let path: String
        switch subject {
        case .user(let id):
            path = Endpoint.userAvatar(id, size: size, dark: dark)
        case .conversation(let token, _):
            guard supportsConversationAvatars else { return nil }
            path = Endpoint.conversationAvatar(token, dark: dark)
        }

        do {
            var request = OCSRequest.get(path)
            request.timeout = 20
            let response = try await client.sendRaw(request)
            guard let image = NSImage(data: response.body) else { return nil }
            store(image, for: key)
            await diskCache.write(response.body, key: key)
            return image
        } catch {
            // An avatar is decoration; a failure is never worth surfacing to the user.
            Log.ui.debug("Avatar fetch failed")
            return nil
        }
    }

    private func store(_ image: NSImage, for key: String) {
        if memory.count >= memoryLimit { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
    }

    private func cacheKey(_ subject: Subject, size: Int, dark: Bool) -> String {
        let suffix = "\(size)\(dark ? "-dark" : "")"
        switch subject {
        case .user(let id):
            return "user-\(Self.sanitize(id))-\(suffix)"
        case .conversation(let token, let version):
            // The version is what makes it safe to keep this indefinitely.
            return "room-\(Self.sanitize(token))-\(Self.sanitize(version))-\(suffix)"
        }
    }

    private static func sanitize(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }
}

/// Disk half of the avatar cache. An actor so file I/O stays off the main thread; it only
/// ever moves `Data`, which crosses actor boundaries freely.
private actor AvatarDiskCache {
    private let directory: URL?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        directory = caches?.appendingPathComponent("app.kvidr.mac/Avatars", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func read(key: String) -> Data? {
        guard let url = fileURL(key) else { return nil }
        return try? Data(contentsOf: url)
    }

    func write(_ data: Data, key: String) {
        guard let url = fileURL(key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(_ key: String) -> URL? {
        directory?.appendingPathComponent("\(key).img")
    }
}
