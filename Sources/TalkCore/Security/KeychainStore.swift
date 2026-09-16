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
/// - Every query that writes sets `kSecUseDataProtectionKeychain`, which is what makes the
///   line above true: without it these are items in the legacy file keychain, where
///   `kSecAttrAccessible` is ignored and reach is decided by a per-item ACL rather than by
///   our signing identity.
/// - An item written by a build from before that key lives in the *other* keychain, and a
///   query carrying the key cannot see it. Left alone it would be an app password that is
///   never read, never deleted and never revoked, while staying perfectly valid on the
///   server — an orphan for the whole installed base, not "one re-login". So a read that
///   misses falls back to the legacy query once and *moves* what it finds, and a delete
///   always sweeps both places. Nothing here ever writes a legacy item again.
/// - Nothing else in the app is allowed to read or write these items.
struct KeychainStore: CredentialStore {
    let service: String

    init(service: String? = nil) {
        self.service = service ?? Bundle.main.bundleIdentifier ?? "app.kvidr.mac"
    }

    func credentials(for accountID: String) throws -> Credentials? {
        // A miss in the data-protection keychain is not proof there is no credential.
        // Moving rather than merely reading is the point: from here on it is an ordinary
        // item that `remove(for:)` — and therefore sign-out's revoke-then-delete — can act
        // on, instead of a valid app password nothing in the app can reach.
        try LegacyCredentialMigration.read(
            current: { try self.read(accountID: accountID, dataProtection: true) },
            legacy: { try self.read(accountID: accountID, dataProtection: false) },
            adopt: { try self.add($0, for: accountID) },
            forget: { try self.delete(accountID: accountID, dataProtection: false) },
            report: {
                Log.auth.warning("Couldn’t move a saved app password into the data-protection keychain: \(String(describing: $0))")
            }
        )
    }

    func store(_ credentials: Credentials, for accountID: String) throws {
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
        try delete(accountID: accountID, dataProtection: true)

        // The legacy sweep is best effort here, and only here. A pre-upgrade item that
        // refuses to go is worth a line in the log; it is not worth a login the user
        // cannot complete, and it is not what this delete is defending against anyway —
        // the squat it guards against can only happen in the keychain we add to.
        // `remove(for:)` takes the strict view, because there the difference between
        // "gone" and "still sitting in your keychain" is the thing being reported.
        do {
            try delete(accountID: accountID, dataProtection: false)
        } catch {
            Log.auth.warning("Couldn’t clear a pre-upgrade keychain item while saving a new one")
        }

        try add(credentials, for: accountID)
    }

    func remove(for accountID: String) throws {
        // Both keychains, and both attempted even if the first fails. The legacy item is
        // the one an upgrade would otherwise leave behind for good — still valid on the
        // server, still listed as a device — so it does not get to be skipped because the
        // data-protection delete had a bad day. A failure on either one is thrown, which
        // is what makes sign-out say the item may still be there instead of "all clean".
        var failure: (any Error)?
        do { try delete(accountID: accountID, dataProtection: true) } catch { failure = error }
        do { try delete(accountID: accountID, dataProtection: false) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    private func read(accountID: String, dataProtection: Bool) throws -> Credentials? {
        var query = baseQuery(accountID: accountID, dataProtection: dataProtection)
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

    private func add(_ credentials: Credentials, for accountID: String) throws {
        let payload = try JSONEncoder().encode(
            StoredCredentials(loginName: credentials.loginName, appPassword: credentials.appPassword)
        )
        var insert = baseQuery(accountID: accountID, dataProtection: true)
        insert[kSecValueData as String] = payload
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func delete(accountID: String, dataProtection: Bool) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID, dataProtection: dataProtection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountID: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecAttrSynchronizable as String: false
        ]
        // Has to be on the read, the write and the delete alike: an item added with it is
        // invisible to a lookup without it, and the other way round. The only queries that
        // leave it off are the ones deliberately looking for what it hides — the migration
        // read and the legacy sweep in `remove(for:)`, both of which only read or delete.
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private struct StoredCredentials: Codable {
        let loginName: String
        let appPassword: String
    }
}
#endif
