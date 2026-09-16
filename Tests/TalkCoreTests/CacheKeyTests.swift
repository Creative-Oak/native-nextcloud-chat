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

    // MARK: - Identifiers too long to spell out

    /// A filename stops at 255 bytes, so an unbounded key is not a key at all: the write
    /// fails, the read fails, and the entry misses *every* time it is looked up. The server
    /// picks the identifier, so it can mint as many permanently-uncacheable ones as it likes
    /// and have each of them refetched on every render, forever.
    @Test("No key is ever longer than the bound", arguments: [1, 55, 56, 57, 200, 4000])
    func neverExceedsTheBound(_ byteCount: Int) {
        let key = CacheKey.fileName(String(repeating: "a", count: byteCount))
        #expect(key.count <= CacheKey.maximumLength)
    }

    @Test("A key long enough to fit is still spelled out in full")
    func shortIdentifiersAreUnchanged() {
        let identifier = String(repeating: "a", count: 56)
        let key = CacheKey.fileName(identifier)
        #expect(key.count == 112)
        #expect(key.allSatisfy { $0.isHexDigit })
    }

    @Test("A bounded key is a fixed width, and a fixed one")
    func boundedKeysArePinned() {
        let key = CacheKey.fileName(String(repeating: "a", count: 57))
        #expect(key.count == 81)
        // Pinned, because the name has to be the same one next launch or the cache is a
        // write-only directory: prefix, hash of the whole identifier, then its length.
        #expect(key == "x61616161616161616161616161616161616161616161616136819478e9f520540000000000000039")
    }

    @Test("Truncation on its own is what this is not")
    func longIdentifiersSharingAPrefixStayApart() {
        // The R4-5 collision, one size up: two ids that agree for their first thirty characters
        // and differ after it. A key that only kept a prefix would merge them and hand one
        // account the other's face again.
        let first = String(repeating: "u", count: 30) + "alpha" + String(repeating: "z", count: 30)
        let second = String(repeating: "u", count: 30) + "bravo" + String(repeating: "z", count: 30)
        #expect(CacheKey.fileName(first) != CacheKey.fileName(second))
    }

    @Test("Length alone tells two otherwise-identical prefixes apart")
    func longIdentifiersOfDifferentLengthsStayApart() {
        let short = String(repeating: "a", count: 57)
        let long = String(repeating: "a", count: 58)
        #expect(CacheKey.fileName(short) != CacheKey.fileName(long))
    }

    @Test("A bounded key and a spelled-out one can never be the same string")
    func theTwoFormsCannotCollide() {
        // Hex has no `x` in it, so the marker that opens a bounded name cannot begin a
        // spelled-out one — which is what keeps the two namespaces disjoint without anyone
        // having to reason about lengths.
        let bounded = CacheKey.fileName(String(repeating: "a", count: 200))
        #expect(bounded.hasPrefix("x"))
        #expect(!CacheKey.fileName("alice").hasPrefix("x"))
    }

    @Test("A bounded key is still filename-safe, and still joins unambiguously")
    func boundedKeysStaySafe() {
        let key = CacheKey.fileName(String(repeating: "../etc/passwd:", count: 30))
        #expect(key.allSatisfy { ($0.isHexDigit && !$0.isUppercase) || $0 == "x" })
        #expect(!key.contains("/"))
        #expect(!key.contains("."))
        // The avatar cache splits `room-<token>-<version>-<size>` on `-`, so no key may
        // contain one, however long the identifier behind it was.
        #expect(!key.contains("-"))
    }

    @Test("The same long identifier always gives the same key")
    func boundedKeysAreDeterministic() {
        let identifier = String(repeating: "alice.smith@corp.example", count: 20)
        #expect(CacheKey.fileName(identifier) == CacheKey.fileName(identifier))
    }
}
