import AppKit
import Foundation

/// Fetches and caches avatars.
///
/// Three rules: never block a row on a network call, never fetch the same avatar twice
/// concurrently, and key the cache on the server's own version string so a changed avatar
/// busts the cache and an unchanged one never refetches.
actor AvatarLoader {
    private let client: OCSClient
    private let server: ServerAddress
    private let supportsConversationAvatars: Bool

    private var memory: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let diskCacheURL: URL?

    /// Small enough that the whole sidebar's worth of avatars is a few megabytes.
    private let memoryLimit = 300

    init(client: OCSClient, server: ServerAddress, supportsConversationAvatars: Bool) {
        self.client = client
        self.server = server
        self.supportsConversationAvatars = supportsConversationAvatars

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        diskCacheURL = caches?.appendingPathComponent("dk.creativeoak.TalkForMac/Avatars", isDirectory: true)
        if let diskCacheURL {
            try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        }
    }

    enum Subject: Sendable, Hashable {
        case user(id: String)
        case conversation(token: String, version: String)
    }

    /// Returns immediately from memory when possible; otherwise loads off the main actor.
    func image(for subject: Subject, size: Int, dark: Bool) async -> NSImage? {
        let key = cacheKey(subject, size: size, dark: dark)
        if let cached = memory[key] { return cached }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.load(subject, size: size, dark: dark, key: key)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func cachedImage(for subject: Subject, size: Int, dark: Bool) -> NSImage? {
        memory[cacheKey(subject, size: size, dark: dark)]
    }

    private func load(_ subject: Subject, size: Int, dark: Bool, key: String) async -> NSImage? {
        if let fromDisk = readFromDisk(key: key) {
            store(fromDisk, for: key)
            return fromDisk
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
            writeToDisk(response.body, key: key)
            return image
        } catch {
            // An avatar is decoration. Failing to fetch one is never worth surfacing.
            Log.ui.debug("Avatar fetch failed for \(key)")
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
            return "user-\(sanitize(id))-\(suffix)"
        case .conversation(let token, let version):
            // The version is what makes this cache safe to keep indefinitely.
            return "room-\(sanitize(token))-\(sanitize(version))-\(suffix)"
        }
    }

    private func sanitize(_ value: String) -> String {
        String(value.map { $0.isLetterOrDigitOrDash ? $0 : "_" })
    }

    private func fileURL(key: String) -> URL? {
        diskCacheURL?.appendingPathComponent("\(key).img")
    }

    private func readFromDisk(key: String) -> NSImage? {
        guard let url = fileURL(key: key), let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func writeToDisk(_ data: Data, key: String) {
        guard let url = fileURL(key: key) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension Character {
    var isLetterOrDigitOrDash: Bool { isLetter || isNumber || self == "-" || self == "_" }
}
