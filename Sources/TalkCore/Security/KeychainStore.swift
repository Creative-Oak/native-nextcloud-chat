import Foundation

#if canImport(Security)
import Security

/// App passwords in the macOS Keychain, as generic passwords.
///
/// - The account id is the keychain `account`, the bundle id is the `service` — taken from
///   the running bundle so that changing `PRODUCT_BUNDLE_IDENTIFIER` doesn't quietly
///   orphan the stored credentials. The literal is only the fallback for a context with no
///   bundle, such as a Linux test run.
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the secret on this Mac:
///   it is a per-device credential and has no business syncing anywhere.
/// - Every query sets `kSecUseDataProtectionKeychain`, which is what makes the line above
///   true: without it these are items in the legacy file keychain, where `kSecAttrAccessible`
///   is ignored and reach is decided by a per-item ACL rather than by our signing identity.
///   Items written by a build that predates this key are in the other keychain and simply
///   will not be found — that costs one re-login, which is the right price.
/// - Nothing else in the app is allowed to read or write these items.
struct KeychainStore: CredentialStore {
    let service: String

    init(service: String? = nil) {
        self.service = service ?? Bundle.main.bundleIdentifier ?? "app.kvidr.mac"
    }

    func credentials(for accountID: String) throws -> Credentials? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data)
            else { throw KeychainError.malformedData }
            return Credentials(loginName: stored.loginName, appPassword: stored.appPassword)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func store(_ credentials: Credentials, for accountID: String) throws {
        let payload = try JSONEncoder().encode(
            StoredCredentials(loginName: credentials.loginName, appPassword: credentials.appPassword)
        )

        // Always add, never update. `SecItemUpdate` writes the data into whichever item
        // already occupies this service/account pair and leaves its attributes — including
        // its access control — exactly as they were, and the pair is entirely predictable
        // (bundle id, then server URL and login name). A process running as the same user
        // could therefore park an item there first and have us fill it with the app
        // password. Deleting first means the item the secret lands in is always one this
        // call just created, with the accessibility set below.
        //
        // A delete that fails is thrown rather than swallowed: the alternative is adding a
        // second item beside the squatted one, or silently leaving the old secret in place.
        try remove(for: accountID)

        var insert = baseQuery(accountID: accountID)
        insert[kSecValueData as String] = payload
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func remove(for accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecAttrSynchronizable as String: false,
            // Has to be on the read, the write and the delete alike: an item added with it
            // is invisible to a lookup without it, and the other way round.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private struct StoredCredentials: Codable {
        let loginName: String
        let appPassword: String
    }
}
#endif
