import Foundation

/// Turns an identifier the app doesn't control — a Nextcloud user id, a conversation token —
/// into a name a file on disk can safely be given.
///
/// Three properties are needed, and the obvious implementation only has the first:
///
/// - *Safe*: the result can never be `..`, an absolute path, or anything with a separator in
///   it, so a key can never name a file outside the cache directory.
/// - *Injective*: two identifiers that differ produce keys that differ. Substituting every
///   awkward character for `_` fails this, and quietly. Nextcloud allows `.`, `_`, `@` and
///   `+` in a user id, so `alice.smith` and `alice_smith` would share one cached avatar and
///   whoever was fetched first would wear the other's face until the file expired — a
///   working impersonation aid in a messaging client, for the cost of registering a name.
/// - *Bounded*: a filename stops at 255 bytes. A key longer than that names a file that can
///   neither be written nor read, so the entry is a miss every single time it is looked up —
///   and the server chooses the identifier, so it can mint as many permanently-uncacheable
///   ones as it likes and have the client refetch each of them on every render.
///
/// Hex, rather than a digest, because this module carries no crypto dependency and the
/// property that matters here is injectivity, not opacity — and rather than a reversible
/// escape over a mixed alphabet, because macOS filesystems are case-insensitive by default,
/// where `Alice` and `alice` are two accounts but one filename. Lowercase hex has one case,
/// no separators and no dots, so it is injective on disk as well as in principle.
enum CacheKey {
    /// No key is ever longer than this.
    ///
    /// Two of them still have to fit inside one filename: the avatar cache's conversation key
    /// is `room-<token>-<version>-<size>-dark.img`, which is 20 characters of scaffolding
    /// around two keys, so 112 each leaves 11 bytes spare against the filesystem's 255.
    static let maximumLength = 112

    /// A filename-safe, collision-free spelling of `identifier`.
    ///
    /// Twice the length of the input in bytes, up to ``maximumLength`` — which is every
    /// identifier of 56 bytes or fewer, i.e. every one a Nextcloud will actually issue. Past
    /// that the name is bounded instead, and how is described on ``boundedName(_:)``.
    static func fileName(_ identifier: String) -> String {
        let bytes = Array(identifier.utf8)
        guard bytes.count * 2 > maximumLength else { return hex(bytes) }
        return boundedName(bytes)
    }

    /// A fixed-width name for an identifier too long to spell out.
    ///
    /// Truncation on its own is exactly the collision this type exists to prevent — two ids
    /// sharing a long prefix would share a face again — so what is kept is a prefix *plus*
    /// the identifier's length *plus* a hash of all of it. The leading `x` is not a hex
    /// digit, which is what keeps the two forms from ever colliding with each other: no
    /// spelled-out key starts with one.
    ///
    /// Injectivity is not recoverable here — no fixed-width name can be injective over
    /// inputs of unbounded length — so what is claimed instead is narrower and true: every
    /// identifier short enough to spell out still gets a provably unique key, and two
    /// identifiers can only land on the same bounded name if they agree on their first 24
    /// bytes, agree on their length, and collide in the hash. Both of those identifiers are
    /// then over 56 bytes, which means both were invented by the server rather than issued
    /// to a person — and a server that controls both names already controls both avatars,
    /// so the collision buys it nothing it could not do directly.
    private static func boundedName(_ bytes: [UInt8]) -> String {
        var name = "x"
        name += hex(Array(bytes.prefix(prefixByteCount)))
        name += hex64(fnv1a(bytes))
        name += hex64(UInt64(bytes.count))
        return name
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    /// Sixteen hex digits, never fewer, so the pieces of a bounded name cannot slide into
    /// each other.
    private static func hex64(_ value: UInt64) -> String {
        var out = ""
        out.reserveCapacity(16)
        var shift = 60
        while shift >= 0 {
            out.append(digits[Int((value >> UInt64(shift)) & 0xF)])
            shift -= 4
        }
        return out
    }

    /// FNV-1a, which is not a cryptographic hash and is not being asked to be one: it is
    /// here to spread identifiers that already share a prefix and a length, in a module that
    /// has to build on Linux without a crypto dependency. See ``boundedName(_:)`` for why a
    /// collision here is not worth anything to the only party who could arrange it.
    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// 1 + 48 + 16 + 16 = 81 characters, comfortably inside ``maximumLength``.
    private static let prefixByteCount = 24

    private static let digits: [Character] = Array("0123456789abcdef")
}
