import Foundation

#if canImport(Security)
import Security

/// App passwords in the macOS Keychain, as generic passwords.
///
/// - The account id is the keychain `account`, the bundle id is the `service`.
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the secret on this Mac:
///   it is a per-device credential and has no business syncing anywhere.
/// - Nothing else in the app is allowed to read or write these items.
struct KeychainStore: CredentialStore {
    let service: String

    init(service: String = "dk.creativeoak.TalkForMac") {
        self.service = service
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

        let query = baseQuery(accountID: accountID)
        let attributes: [String: Any] = [kSecValueData as String: payload]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var insert = query
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
            kSecAttrSynchronizable as String: false
        ]
    }

    private struct StoredCredentials: Codable {
        let loginName: String
        let appPassword: String
    }
}
#endif
