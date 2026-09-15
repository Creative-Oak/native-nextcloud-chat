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
            // Not after a purge: a fetch still in flight when the account signed out must
            // not put back what the purge has just cleared away.
            guard !Task.isCancelled else { return nil }
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

    /// The name of one cached avatar, in memory and on disk both.
    ///
    /// Through ``CacheKey/fileName(_:)`` rather than by substituting the awkward characters
    /// away: a user id is not ours to choose, and collapsing `.`, `_`, `@` and `+` — all of
    /// which Nextcloud allows — to the same character made `alice.smith` and `alice_smith`
    /// one cache entry, so whoever was fetched first wore the other's face for a day. The
    /// escape is injective, which is the property that closes that; it also only ever
    /// produces hex digits, so a key still cannot name a file outside the cache directory.
    private func cacheKey(_ subject: Subject, size: Int, dark: Bool) -> String {
        let suffix = "\(size)\(dark ? "-dark" : "")"
        switch subject {
        case .user(let id):
            return "user-\(CacheKey.fileName(id))-\(suffix)"
        case .conversation(let token, let version):
            // The version is what makes it safe to keep this indefinitely. Hex carries no
            // `-`, so the join back to one string is unambiguous too: no token and version
            // can be split at a different place and come out the same.
            return "room-\(CacheKey.fileName(token))-\(CacheKey.fileName(version))-\(suffix)"
        }
    }

    /// Throws away everything this loader has cached — the images in memory and the files on
    /// disk both — and leaves it usable afterwards.
    ///
    /// For sign-out. The disk half is one file per person and one per conversation the
    /// account ever saw, each named after them, in a directory that nothing else empties; a
    /// Mac that has been signed out should not still be holding the account's contact list
    /// and its room tokens, with photographs.
    func purge() async {
        memory.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        await diskCache.purge()
    }
}

/// Disk half of the avatar cache. An actor so file I/O stays off the main thread; it only
/// ever moves `Data`, which crosses actor boundaries freely.
private actor AvatarDiskCache {
    private let directory: URL
    private var writesSinceTrim = 0

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
        writesSinceTrim += 1
        if writesSinceTrim >= Self.writesBetweenTrims {
            writesSinceTrim = 0
            trim()
        }
    }

    /// Empties the cache, then puts the directory back so the loader still works.
    func purge() {
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Keeps the cache to a budget, oldest first.
    ///
    /// Nothing else ever removed a file here: a server is free to answer the avatar endpoint
    /// with a large body for every user id it is asked about, and a busy account asks about
    /// a great many. The age limit is the same idea from the other end — a conversation
    /// avatar's key names its own version, so it would otherwise be kept forever, including
    /// for conversations the user left years ago.
    ///
    /// From the write path rather than a timer, every so many writes, because the cost is a
    /// directory listing and the cache only grows when something is written to it.
    private func trim() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, modified: Date, size: Int)] = files.map { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (
                url: file,
                modified: values?.contentModificationDate ?? Date.distantPast,
                size: values?.fileSize ?? 0
            )
        }
        entries.sort { $0.modified < $1.modified }

        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries {
            // Sorted oldest first, so once one file is both young enough and within budget,
            // so is everything after it.
            guard Date.now.timeIntervalSince(entry.modified) > Self.maximumAge || total > Self.byteBudget
            else { break }
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static let writesBetweenTrims = 50
    private static let byteBudget = 20 * 1024 * 1024
    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private func fileURL(_ key: String) -> URL {
        directory.appending(path: "\(key).img")
    }
}
