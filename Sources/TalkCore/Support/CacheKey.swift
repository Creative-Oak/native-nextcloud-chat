import Foundation

/// Turns an identifier the app doesn't control — a Nextcloud user id, a conversation token —
/// into a name a file on disk can safely be given.
///
/// Two properties are needed, and the obvious implementation only has the first:
///
/// - *Safe*: the result can never be `..`, an absolute path, or anything with a separator in
///   it, so a key can never name a file outside the cache directory.
/// - *Injective*: two identifiers that differ produce keys that differ. Substituting every
///   awkward character for `_` fails this, and quietly. Nextcloud allows `.`, `_`, `@` and
///   `+` in a user id, so `alice.smith` and `alice_smith` would share one cached avatar and
///   whoever was fetched first would wear the other's face until the file expired — a
///   working impersonation aid in a messaging client, for the cost of registering a name.
///
/// Hex, rather than a digest, because this module carries no crypto dependency and the
/// property that matters here is injectivity, not opacity — and rather than a reversible
/// escape over a mixed alphabet, because macOS filesystems are case-insensitive by default,
/// where `Alice` and `alice` are two accounts but one filename. Lowercase hex has one case,
/// no separators and no dots, so it is injective on disk as well as in principle.
enum CacheKey {
    /// A filename-safe, collision-free spelling of `identifier`.
    ///
    /// Twice the length of the input in bytes. Filenames stop at 255, so an identifier over
    /// about a hundred characters would make a name the filesystem refuses; every caller
    /// here treats a failed cache write as a cache miss, which is the right outcome anyway.
    static func fileName(_ identifier: String) -> String {
        var hex = ""
        hex.reserveCapacity(identifier.utf8.count * 2)
        for byte in identifier.utf8 {
            hex.append(Self.digits[Int(byte >> 4)])
            hex.append(Self.digits[Int(byte & 0x0F)])
        }
        return hex
    }

    private static let digits: [Character] = Array("0123456789abcdef")
}
