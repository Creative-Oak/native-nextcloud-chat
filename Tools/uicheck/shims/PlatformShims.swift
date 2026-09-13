// Stand-ins for the parts of the core that need a macOS SDK, so the rest of the app can be
// type-checked without one.
//
// These mirror the real declarations' *signatures* exactly — which is the point: the check
// verifies that the app calls them correctly. Their bodies are irrelevant and never run.
import Foundation

struct KeychainStore: CredentialStore {
    let service: String
    init(service: String = "dk.creativeoak.TalkForMac") { self.service = service }
    func credentials(for accountID: String) throws -> Credentials? { nil }
    func store(_ credentials: Credentials, for accountID: String) throws {}
    func remove(for accountID: String) throws {}
}

actor SystemNetworkMonitor: NetworkMonitoring {
    init() {}
    var state: ConnectionState { get async { .online } }
    func states() async -> AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
}

/// `ModelContainer.talkContainer` lives in the core's SwiftData file, which can't be
/// compiled here — so the extension it declares is restated, with the same signature.
import SwiftData

extension ModelContainer {
    static func talkContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(for: Schema([]), configurations: [ModelConfiguration()])
    }
}

enum CacheSchema {
    static var models: [Any] { [] }
}

actor TalkStore {
    init(modelContainer: ModelContainer) {}

    func accounts() -> [Account] { [] }
    func save(account: Account) {}
    func deleteAccount(id accountID: String) {}

    func conversations(accountID: String) -> [Conversation] { [] }
    func save(conversations: [Conversation], accountID: String) {}
    func deleteConversations(tokens: [String], accountID: String) {}

    func messages(token: String, accountID: String, limit: Int = 200) -> [Message] { [] }
    func save(messages: [Message], accountID: String) {}
    func deleteMessage(localID: String, token: String, accountID: String) {}
    func trimMessages(token: String, accountID: String, keeping: Int = 500) {}

    func draft(token: String, accountID: String) -> Draft? { nil }
    func drafts(accountID: String) -> [Draft] { [] }
    func save(draft: Draft, accountID: String) {}

    func syncState(accountID: String) -> SyncCursor { SyncCursor() }
    func save(syncState: SyncCursor, accountID: String) {}
}
