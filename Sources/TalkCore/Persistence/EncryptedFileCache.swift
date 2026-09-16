import Foundation

#if canImport(CryptoKit)

/// Files on disk, each sealed with the account's key, kept to a byte budget by evicting the
/// least recently used.
///
/// For pictures, which are too large to belong in the database and too personal to leave in
/// the clear: a transcript's shared photos say more about someone than its text does.
actor EncryptedFileCache {
    let directory: URL
    private let sealer: CacheSealer
    private let byteBudget: Int
    private var bytesSinceTrim = 0
    private var isPrepared = false

    init(directory: URL, sealer: CacheSealer, byteBudget: Int) {
        self.directory = directory
        self.sealer = sealer
        self.byteBudget = byteBudget
    }

    func read(_ name: String) -> Data? {
        let url = fileURL(name)
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        guard let data = sealer.open(sealed) else {
            // Written before encryption, under a destroyed key, or damaged: never readable,
            // so not worth its space.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Reading is use: the eviction order is by when a file was last wanted.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
        return data
    }

    func write(_ data: Data, name: String) {
        guard let sealed = sealer.seal(data) else { return }
        prepare()
        try? sealed.write(to: fileURL(name), options: .atomic)
        bytesSinceTrim += sealed.count
        // Swept once a tenth of the budget has been written, so the cache never overshoots
        // by more than that plus one file.
        if bytesSinceTrim >= max(byteBudget / 10, 1) {
            bytesSinceTrim = 0
            trim()
        }
    }

    func remove(namesWithPrefix prefix: String) {
        for file in files() where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func purge() {
        try? FileManager.default.removeItem(at: directory)
        isPrepared = false
        bytesSinceTrim = 0
    }

    /// The bytes on disk right now, for tests and nothing else.
    func totalBytes() -> Int {
        files().reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func prepare() {
        guard !isPrepared else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isPrepared = true
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var entries = files().map { file in
            let values = try? file.resourceValues(forKeys: keys)
            return (url: file, used: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }
        entries.sort { $0.used < $1.used }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > byteBudget {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: []
        )) ?? []
    }

    /// Names are hex (see ``CacheKey``), so they can't leave the directory.
    private func fileURL(_ name: String) -> URL {
        directory.appending(path: "\(name).bin")
    }
}
#endif
