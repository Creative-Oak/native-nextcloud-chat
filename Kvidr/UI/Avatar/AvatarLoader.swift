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
@Observable
final class AvatarLoader {
    enum Subject: Sendable, Hashable {
        case user(id: String)
        case conversation(token: String, version: String)
    }

    private let client: OCSClient
    private let supportsConversationAvatars: Bool

    @ObservationIgnored private var memory: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let diskCache: AvatarDiskCache
    /// Bumped per person when their picture is known to have changed. Views showing a user
    /// avatar include it in what they load on, so they all ask again at once.
    private(set) var userRevisions: [String: Int] = [:]

    /// A few hundred small images is a couple of megabytes — well worth never refetching.
    private let memoryLimit = 300

    /// Avatars on disk are sealed with the account's key, like the rest of its cache: a
    /// directory of colleagues' faces, each file named for one of them, is not something to
    /// leave readable — or readable after signing out.
    private let sealer: CacheSealer

    init(client: OCSClient, supportsConversationAvatars: Bool, sealer: CacheSealer) {
        self.client = client
        self.supportsConversationAvatars = supportsConversationAvatars
        self.sealer = sealer
        // One cache, however many loaders. A loader is rebuilt whenever the server says its
        // capabilities moved, and the disk cache's idea of how much it has written since it
        // last swept up lived on the loader — so a server that changed one capability every
        // few dozen avatars reset the budget before it was ever reached, and the sweep never
        // ran at all. The state has to outlive the loader for the budget to mean anything.
        self.diskCache = AvatarDiskCache.shared
        Task { await AvatarDiskCache.shared.prepareOnce() }
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
        if let sealed = await diskCache.read(key: key, maximumAge: maximumAge),
           let data = sealer.open(sealed),
           let image = Self.image(from: data, size: size) {
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
            // A profile picture, at the sizes this asks for, is tens of kilobytes. The
            // general API ceiling — sixteen megabytes — is not a limit on a decoration, so
            // the request carries its own and the transport stops reading at it, rather
            // than taking the whole thing and being told afterwards.
            request.maximumResponseSize = Self.maximumAvatarBytes
            let response = try await client.sendRaw(request)
            // Belt and braces: the transport refuses the oversized body, and nothing keeps
            // a copy of one that slipped through a ceiling raised later by mistake.
            guard response.body.count <= Self.maximumAvatarBytes else {
                Log.ui.debug("Avatar response was far too large to be a profile picture")
                return nil
            }
            guard let image = Self.image(from: response.body, size: size) else { return nil }
            // Not after a purge: a fetch still in flight when the account signed out must
            // not put back what the purge has just cleared away.
            guard !Task.isCancelled else { return nil }
            store(image, for: key)
            if let sealed = sealer.seal(response.body) {
                await diskCache.write(sealed, key: key)
            }
            return image
        } catch {
            // An avatar is decoration; a failure is never worth surfacing to the user.
            Log.ui.debug("Avatar fetch failed")
            return nil
        }
    }

    /// A picture from the server's bytes. An emoji picture Talk made is drawn here from its
    /// colour and emoji — see ``EmojiAvatar`` for why its SVG isn't used as it is.
    private static func image(from data: Data, size: Int) -> NSImage? {
        guard let emoji = EmojiAvatar.parse(data) else { return NSImage(data: data) }
        let side = CGFloat(max(size, 32))
        let rgb = emoji.rgb
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            rect.fill()
            let font = NSFont.systemFont(ofSize: side * 0.5)
            let text = NSAttributedString(string: emoji.emoji, attributes: [.font: font])
            let bounds = text.size()
            text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
            return true
        }
    }

    /// What an avatar is allowed to weigh.
    private static let maximumAvatarBytes = 2 * 1024 * 1024

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
    /// escape is injective, which is the property that closes that; it is also bounded, and
    /// spells names out of hex digits and nothing else, so a key can neither name a file
    /// outside the cache directory nor one the filesystem refuses to open.
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

    /// Forgets one person's picture, in memory and on disk, and tells every view showing it.
    ///
    /// For the signed-in user's own picture after they change it: a user avatar's key says
    /// who, never which picture, so without this the old one would be served from the
    /// cache for up to a day.
    func forget(userID: String) async {
        let prefix = "user-\(CacheKey.fileName(userID))-"
        for key in memory.keys where key.hasPrefix(prefix) { memory[key] = nil }
        for (key, task) in inFlight where key.hasPrefix(prefix) {
            task.cancel()
            inFlight[key] = nil
        }
        await diskCache.remove(keysWithPrefix: prefix)
        userRevisions[userID, default: 0] += 1
    }

    func revision(ofUser userID: String) -> Int {
        userRevisions[userID] ?? 0
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
///
/// One instance for the whole process, because the budget below is only a budget if it
/// survives everything that can replace an ``AvatarLoader``.
private actor AvatarDiskCache {
    static let shared = AvatarDiskCache()

    /// The cache directory, and the one the current key format lives in inside it.
    private let root: URL
    private let directory: URL
    private var bytesSinceTrim = 0
    private var hasPrepared = false

    init() {
        let root = URL.cachesDirectory.appending(path: "app.kvidr.mac/Avatars", directoryHint: .isDirectory)
        let directory = root.appending(path: Self.formatVersion, directoryHint: .isDirectory)
        self.root = root
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Once per launch: collect what an older build left behind, and put the cache back
    /// inside its budget before anything is added to it.
    ///
    /// Trimming only from the write path meant a Mac that was never signed out could carry
    /// whatever the last run left there indefinitely, because the sweep is only reached by
    /// writing enough to trigger it. Two directory listings at startup is not a cost worth
    /// avoiding.
    func prepareOnce() {
        guard !hasPrepared else { return }
        hasPrepared = true
        removeSupersededFormats()
        trim()
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
        // Bytes rather than a count of writes. A count only bounds the directory if every
        // file is about the same size, and nothing on the other end of this promises that:
        // the transport's ceiling is sixteen megabytes, so fifty writes between sweeps was
        // eight hundred megabytes against a twenty megabyte budget. Counting what was
        // actually written makes the overshoot the same size whatever the server sends.
        bytesSinceTrim += data.count
        if bytesSinceTrim >= Self.bytesBetweenTrims {
            bytesSinceTrim = 0
            trim()
        }
    }

    func remove(keysWithPrefix prefix: String) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? manager.removeItem(at: file)
        }
    }

    /// Empties the cache, then puts the directory back so the loader still works.
    func purge() {
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        bytesSinceTrim = 0
    }

    /// Deletes avatars cached under a key format this build no longer uses.
    ///
    /// The names changed when the escape did, so those files can never be read again — and
    /// they are the ones that hold the previous format's problem: a directory full of
    /// filenames each naming a colleague of whoever used this Mac, readable by anything that
    /// can read the user's caches, kept for as long as the Mac runs. Eviction on age and size
    /// would take them eventually and only eventually; this takes them at the next launch.
    ///
    /// By directory rather than by pattern-matching names, so a format that has been gone for
    /// two releases is collected as surely as the one before it, without anything having to
    /// remember how it used to spell things.
    private func removeSupersededFormats() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.lastPathComponent != Self.formatVersion {
            try? manager.removeItem(at: entry)
        }
    }

    /// Keeps the cache to a budget, oldest first.
    ///
    /// Nothing else ever removed a file here: a server is free to answer the avatar endpoint
    /// with a large body for every user id it is asked about, and a busy account asks about
    /// a great many. The age limit is the same idea from the other end — a conversation
    /// avatar's key names its own version, so it would otherwise be kept forever, including
    /// for conversations the user left years ago.
    ///
    /// Hidden files are listed too, unlike everywhere else: an atomic write that was
    /// interrupted leaves a dot-prefixed temporary behind, and skipping those meant they were
    /// neither counted against the budget nor ever collected.
    private func trim() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
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

    /// The subdirectory the current key format writes into. Bumped whenever the shape of a
    /// key changes, which is what makes the previous format's files identifiable and so
    /// removable — see ``removeSupersededFormats()``.
    /// 3: sealed with the account's key. A version-2 file is readable by anyone, and is
    /// removed at launch like any other superseded format.
    private static let formatVersion = "3"
    /// How much may be written between two sweeps. The cache therefore never exceeds its
    /// budget by more than this plus one avatar.
    private static let bytesBetweenTrims = 4 * 1024 * 1024
    private static let byteBudget = 20 * 1024 * 1024
    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private func fileURL(_ key: String) -> URL {
        directory.appending(path: "\(key).img")
    }
}
