import Foundation

#if canImport(CryptoKit)
import CryptoKit

/// Seals and opens one kind of cached file for one account, fetching the account's key from
/// the keychain once rather than for every file.
///
/// For the caches that live as files rather than in the database — pictures — so they are
/// under the same key as the rest of the account's cache, and signing out makes them noise.
final class CacheSealer: @unchecked Sendable {
    let accountID: String
    let kind: CacheCipher.Kind
    private let keyring: any CacheKeyring
    private let lock = NSLock()
    private var key: SymmetricKey?

    init(keyring: any CacheKeyring, accountID: String, kind: CacheCipher.Kind) {
        self.keyring = keyring
        self.accountID = accountID
        self.kind = kind
    }

    /// Nil when there is no key to be had — in which case the caller doesn't write, rather
    /// than writing in the clear.
    func seal(_ plaintext: Data) -> Data? {
        guard let key = currentKey() else { return nil }
        return try? CacheCipher.seal(plaintext, kind: kind, key: key)
    }

    /// Nil for anything that won't open: a file from before encryption, one sealed under a
    /// key since destroyed, one of another kind, or one that was tampered with.
    func open(_ sealed: Data) -> Data? {
        guard CacheCipher.isSealed(sealed), let key = currentKey() else { return nil }
        return try? CacheCipher.open(sealed, kind: kind, key: key)
    }

    private func currentKey() -> SymmetricKey? {
        lock.withLock {
            if let key { return key }
            do {
                let fetched = try keyring.key(for: accountID)
                key = fetched
                return fetched
            } catch {
                Log.persistence.error("No cache key for pictures, so none are kept: \(String(describing: error))")
                return nil
            }
        }
    }
}
#endif
