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

enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(Int32)
    case malformedData
}
