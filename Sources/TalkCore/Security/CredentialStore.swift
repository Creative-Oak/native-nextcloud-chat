import Foundation

/// Where app passwords live.
///
/// The only implementation used by the app is ``KeychainStore``. The protocol exists so
/// the auth and sync layers can be tested without touching the login keychain.
protocol CredentialStore: Sendable {
    func credentials(for accountID: String) throws -> Credentials?
    func store(_ credentials: Credentials, for accountID: String) throws
    func remove(for accountID: String) throws
}

/// Test/preview double. Never used in a shipping build.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Credentials] = [:]

    init(_ initial: [String: Credentials] = [:]) { storage = initial }

    func credentials(for accountID: String) throws -> Credentials? {
        lock.withLock { storage[accountID] }
    }

    func store(_ credentials: Credentials, for accountID: String) throws {
        lock.withLock { storage[accountID] = credentials }
    }

    func remove(for accountID: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: accountID) }
    }
}

/// The read half of a credential store that has a second, older place to look in.
///
/// It lives out here, outside the platform guard, for one reason: the macOS Keychain
/// cannot be stood up in a unit test, and the part of a migration worth getting wrong is
/// the order. ``KeychainStore`` is the only caller.
enum LegacyCredentialMigration {
    /// Hands back what `current` holds; failing that, moves what `legacy` holds into
    /// `current` and hands that back.
    ///
    /// The ordering is the whole point. The new copy is written *before* the old one is
    /// deleted, so a failure anywhere leaves the only copy of a live app password where it
    /// was rather than destroying it. A move that could not be completed still returns the
    /// credential, because being unable to tidy up is not a reason to log someone out —
    /// and it is reported, not swallowed. `legacy` is only ever read from and deleted
    /// from; nothing here ever writes one.
    static func read(
        current: () throws -> Credentials?,
        legacy: () throws -> Credentials?,
        adopt: (Credentials) throws -> Void,
        forget: () throws -> Void,
        report: (any Error) -> Void
    ) throws -> Credentials? {
        if let credentials = try current() { return credentials }
        guard let credentials = try legacy() else { return nil }
        do {
            try adopt(credentials)
            try forget()
        } catch {
            report(error)
        }
        return credentials
    }
}

enum KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    case unexpectedStatus(Int32)
    case malformedData

    /// The status is the whole diagnosis — `-34018` is a missing entitlement, `-25308` a
    /// locked keychain — and without this the log says only "KeychainError error 0".
    var description: String {
        switch self {
        case .unexpectedStatus(let status): "keychain status \(status)"
        case .malformedData: "keychain item malformed"
        }
    }
}
