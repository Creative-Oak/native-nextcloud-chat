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

    /// How long a cached user avatar is trusted.
    ///
    /// A conversation avatar's key carries the server's version string, so a cached copy is
    /// current by definition and is kept forever. A user avatar has no such version — the
    /// key can only say *who*, never *which picture* — so on disk it would otherwise
    /// outlive the profile picture it holds, and someone who changes their photo would keep
    /// their old face here indefinitely. A day is long enough that avatars are effectively
    /// free, and short enough that a new one turns up the same day.
    private static let userAvatarMaximumAge: TimeInterval = 24 * 60 * 60

    private func fetch(_ subject: Subject, size: Int, dark: Bool, key: String) async -> NSImage? {
        let maximumAge: TimeInterval? = switch subject {
        case .user: Self.userAvatarMaximumAge
        case .conversation: nil
        }
        if let data = await diskCache.read(key: key, maximumAge: maximumAge), let image = NSImage(data: data) {
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
    private let directory: URL

    init() {
        directory = URL.cachesDirectory.appending(path: "app.kvidr.mac/Avatars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// - Parameter maximumAge: how old the file may be, or `nil` when the key itself
    ///   identifies the content and age therefore says nothing.
    func read(key: String, maximumAge: TimeInterval?) -> Data? {
        let url = fileURL(key)
        if let maximumAge {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date.now.timeIntervalSince(modified) < maximumAge
            else { return nil }
        }
        return try? Data(contentsOf: url)
    }

    func write(_ data: Data, key: String) {
        try? data.write(to: fileURL(key), options: .atomic)
    }

    private func fileURL(_ key: String) -> URL {
        directory.appending(path: "\(key).img")
    }
}
