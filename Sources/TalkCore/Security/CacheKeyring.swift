import Foundation

#if canImport(CryptoKit)
import CryptoKit

/// The keys the local cache is encrypted with, one per account.
///
/// Per account so that signing out of one destroys exactly that account's data: the rows
/// are deleted too, but a deleted SQLite row lingers in the file's free pages and in any
/// backup taken before, and without its key what lingers is noise.
protocol CacheKeyring: Sendable {
    /// The account's key, made the first time it is asked for.
    ///
    /// Throws when the keychain can't answer, and in that case never makes a key: a new one
    /// in place of an existing one it failed to read would make everything already cached
    /// unreadable for good.
    func key(for accountID: String) throws -> SymmetricKey

    /// Destroys the account's key. After this nothing cached for it can be read again.
    func removeKey(for accountID: String) throws
}

/// For tests and previews.
final class InMemoryCacheKeyring: CacheKeyring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]

    init() {}

    func key(for accountID: String) throws -> SymmetricKey {
        lock.withLock {
            if let key = keys[accountID] { return key }
            let key = SymmetricKey(size: .bits256)
            keys[accountID] = key
            return key
        }
    }

    func removeKey(for accountID: String) throws {
        lock.withLock { _ = keys.removeValue(forKey: accountID) }
    }

    func hasKey(for accountID: String) -> Bool {
        lock.withLock { keys[accountID] != nil }
    }
}
#endif

#if canImport(CryptoKit) && canImport(Security)
import Security

/// Cache keys in the data-protection keychain, beside the app passwords but under a service
/// of their own.
///
/// The same rules as ``KeychainStore``: this device only, never synced, and always in the
/// data-protection keychain, where an item belongs to the app's signing identity and no
/// other process can plant one for it to find. Unlike an app password there is no legacy
/// item to adopt — cache keys never existed before this.
struct KeychainCacheKeyring: CacheKeyring {
    let service: String

    init(service: String? = nil) {
        self.service = (service ?? Bundle.main.bundleIdentifier ?? "app.kvidr.mac") + ".cache-key"
    }

    func key(for accountID: String) throws -> SymmetricKey {
        if let existing = try read(accountID: accountID) { return existing }

        let key = SymmetricKey(size: .bits256)
        var insert = baseQuery(accountID: accountID)
        insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Made by someone else between the read and the add; theirs is the one in use.
            guard let existing = try read(accountID: accountID) else { throw KeychainError.malformedData }
            return existing
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removeKey(for accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func read(accountID: String) throws -> SymmetricKey? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { throw KeychainError.malformedData }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
#endif
