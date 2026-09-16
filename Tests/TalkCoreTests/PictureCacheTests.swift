import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TalkCore

@Suite("Picture layout")
struct ImageLayoutTests {
    @Test("A picture keeps the frame its message announced, even when the preview is smaller")
    func keepsAnnouncedFrame() {
        // A 4000×3000 photo whose preview came back at 640×480.
        let frame = ImageLayout.frame(announced: CGSize(width: 4000, height: 3000), original: CGSize(width: 640, height: 480))
        #expect(frame == CGSize(width: 420, height: 315))
        #expect(frame == ImageLayout.frame(announced: CGSize(width: 4000, height: 3000), original: nil),
                "the placeholder and the picture are the same size")
    }

    @Test("A preview rounded to whole pixels is still the same shape")
    func roundingIsSameShape() {
        #expect(ImageLayout.sameShape(CGSize(width: 4032, height: 3024), CGSize(width: 640, height: 479)))
        #expect(ImageLayout.frame(announced: CGSize(width: 4032, height: 3024), original: CGSize(width: 640, height: 479))
                == ImageLayout.frame(announced: CGSize(width: 4032, height: 3024), original: nil))
    }

    @Test("A photo the camera turned on its side takes its real shape")
    func rotatedTakesItsShape() {
        let frame = ImageLayout.frame(announced: CGSize(width: 4000, height: 3000), original: CGSize(width: 480, height: 640))
        #expect(frame == CGSize(width: 390, height: 520))
    }

    @Test("Never scaled up, and something sensible with nothing to go on")
    func limits() {
        #expect(ImageLayout.frame(announced: CGSize(width: 120, height: 80), original: nil) == CGSize(width: 120, height: 80))
        #expect(ImageLayout.frame(announced: nil, original: nil) == ImageLayout.unknownSize)
        #expect(ImageLayout.frame(announced: CGSize(width: 0, height: 0), original: CGSize(width: 200, height: 100)) == CGSize(width: 200, height: 100))
        #expect(ImageLayout.frame(announced: CGSize(width: 1000, height: 5000), original: nil) == CGSize(width: 104, height: 520))
    }

    private func jpeg(width: Int, height: Int, properties: [CFString: Any]) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("Pixel size is in pixels whatever the dpi, and upright")
    func pixelSize() throws {
        let retina = try jpeg(width: 640, height: 480, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        #expect(ImageLayout.pixelSize(of: retina) == CGSize(width: 640, height: 480))

        let sideways = try jpeg(width: 640, height: 480, properties: [kCGImagePropertyOrientation: 6])
        #expect(ImageLayout.pixelSize(of: sideways) == CGSize(width: 480, height: 640))

        #expect(ImageLayout.pixelSize(of: Data("no".utf8)) == nil)
    }
}

/// A keyring that can't answer.
private struct UnavailableKeyring: CacheKeyring {
    func key(for accountID: String) throws -> SymmetricKey { throw KeychainError.unexpectedStatus(-34018) }
    func removeKey(for accountID: String) throws {}
}

@Suite("Encrypted picture cache")
struct EncryptedFileCacheTests {
    private let account = "https://cloud.example.com|alice"

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kvidr-tests-\(UUID().uuidString)")
    }

    @Test("A sealer opens only what it sealed, as the kind it sealed it")
    func sealer() {
        let keyring = InMemoryCacheKeyring()
        let previews = CacheSealer(keyring: keyring, accountID: account, kind: .preview)
        let avatars = CacheSealer(keyring: keyring, accountID: account, kind: .avatar)
        let picture = Data("a photo of the office party".utf8)

        let sealed = previews.seal(picture)
        #expect(sealed != nil)
        #expect(previews.open(sealed ?? Data()) == picture)
        #expect(avatars.open(sealed ?? Data()) == nil, "a preview can't be passed off as an avatar")
        #expect(previews.open(picture) == nil, "a file from before encryption isn't opened")
        #expect(CacheSealer(keyring: InMemoryCacheKeyring(), accountID: account, kind: .preview).open(sealed ?? Data()) == nil)
        #expect(CacheSealer(keyring: UnavailableKeyring(), accountID: account, kind: .preview).seal(picture) == nil,
                "no key means nothing written, not something written in the clear")
    }

    @Test("What goes in comes out, and nothing on disk is readable")
    func roundTrip() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedFileCache(
            directory: directory,
            sealer: CacheSealer(keyring: InMemoryCacheKeyring(), accountID: account, kind: .preview),
            byteBudget: 1_000_000
        )
        let picture = Data("the whiteboard with the launch date on it".utf8)

        await cache.write(picture, name: "abc-640")
        #expect(await cache.read("abc-640") == picture)
        #expect(await cache.read("missing") == nil)

        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: Data("launch date".utf8)) == nil)
        }
    }

    @Test("A file that won't open is thrown away")
    func unreadableIsRemoved() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("plaintext from before".utf8).write(to: directory.appending(path: "old.bin"))
        let cache = EncryptedFileCache(
            directory: directory,
            sealer: CacheSealer(keyring: InMemoryCacheKeyring(), accountID: account, kind: .preview),
            byteBudget: 1_000_000
        )
        #expect(await cache.read("old") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "old.bin").path))
    }

    @Test("Over budget, the least recently used go first")
    func evictsLeastRecentlyUsed() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Room for about three of these once sealed; a sweep after every write.
        let cache = EncryptedFileCache(
            directory: directory,
            sealer: CacheSealer(keyring: InMemoryCacheKeyring(), accountID: account, kind: .preview),
            byteBudget: 3_200
        )
        let picture = Data(repeating: 7, count: 1_000)

        await cache.write(picture, name: "first")
        try await Task.sleep(for: .milliseconds(20))
        await cache.write(picture, name: "second")
        try await Task.sleep(for: .milliseconds(20))
        await cache.write(picture, name: "third")
        try await Task.sleep(for: .milliseconds(20))
        // Looking at the first makes it the most recently used.
        #expect(await cache.read("first") != nil)
        try await Task.sleep(for: .milliseconds(20))
        await cache.write(picture, name: "fourth")

        #expect(await cache.totalBytes() <= 3_200)
        #expect(await cache.read("second") == nil, "the one nobody looked at longest is the one that went")
        #expect(await cache.read("first") != nil)
        #expect(await cache.read("fourth") != nil)
    }

    @Test("Purge leaves nothing, and the cache still works after")
    func purge() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedFileCache(
            directory: directory,
            sealer: CacheSealer(keyring: InMemoryCacheKeyring(), accountID: account, kind: .avatar),
            byteBudget: 1_000_000
        )
        await cache.write(Data("face".utf8), name: "user-61-64")
        await cache.write(Data("face".utf8), name: "user-62-64")
        await cache.remove(namesWithPrefix: "user-61-")
        #expect(await cache.read("user-61-64") == nil)
        #expect(await cache.read("user-62-64") != nil)

        await cache.purge()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await cache.write(Data("again".utf8), name: "x")
        #expect(await cache.read("x") == Data("again".utf8))
    }
}
