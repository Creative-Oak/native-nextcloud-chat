import Foundation
import Testing
@testable import TalkCore

/// A cache key is a filename built from a string the server chose, so it has to be both safe
/// and unique. The avatar cache used to substitute awkward characters away, which is safe and
/// not unique — two user ids one character apart shared a file, and a face with it.
@Suite("Cache keys")
struct CacheKeyTests {
    @Test("The same identifier always gives the same key")
    func deterministic() {
        #expect(CacheKey.fileName("alice") == CacheKey.fileName("alice"))
        #expect(CacheKey.fileName("alice") == "616c696365")
    }

    @Test("Identifiers a substitution would have merged stay apart", arguments: [
        ("alice.smith", "alice_smith"),
        ("alice@corp", "alice_corp"),
        ("alice+work", "alice_work"),
        ("a.b", "a_b"),
        ("a_b", "a b")
    ])
    func injectiveWhereSubstitutionWasNot(_ pair: (String, String)) {
        #expect(CacheKey.fileName(pair.0) != CacheKey.fileName(pair.1))
    }

    @Test("Case is preserved, because filesystems do not preserve it")
    func caseSurvives() {
        // macOS volumes are case-insensitive by default: `Alice` and `alice` are two accounts
        // but would be one file unless the key itself distinguishes them without relying on
        // case. The keys differ, and neither has an uppercase character in it.
        #expect(CacheKey.fileName("Alice") != CacheKey.fileName("alice"))
        #expect(CacheKey.fileName("Alice") == CacheKey.fileName("Alice").lowercased())
    }

    @Test("A key is only ever hex digits", arguments: [
        "../../../../etc/passwd",
        "/etc/passwd",
        "..",
        ".",
        "with/slash",
        "with:colon",
        "with\u{0}nul",
        "emoji 🐈 and ünïcödé",
        ""
    ])
    func alwaysFilenameSafe(_ identifier: String) {
        let key = CacheKey.fileName(identifier)
        #expect(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!key.contains("/"))
        #expect(!key.contains("."))
    }

    @Test("Traversal attempts do not collapse into each other either")
    func traversalStaysDistinct() {
        #expect(CacheKey.fileName("..") != CacheKey.fileName("__"))
        #expect(CacheKey.fileName("../x") != CacheKey.fileName("___x"))
    }

    @Test("Two parts joined by a separator can only be split one way")
    func joinIsUnambiguous() {
        // How the avatar cache composes a room key: `room-<token>-<version>-<size>`. Hex has
        // no `-` in it, so no pair of token and version can be split at a different place and
        // come out the same string.
        let first = "\(CacheKey.fileName("a-b"))-\(CacheKey.fileName("c"))"
        let second = "\(CacheKey.fileName("a"))-\(CacheKey.fileName("b-c"))"
        #expect(first != second)
    }

    @Test("The key is twice the identifier's length in UTF-8 bytes")
    func length() {
        #expect(CacheKey.fileName("abc").count == 6)
        #expect(CacheKey.fileName("\u{00E9}").count == 4)   // é is two bytes in UTF-8
        #expect(CacheKey.fileName("").isEmpty)
    }
}
