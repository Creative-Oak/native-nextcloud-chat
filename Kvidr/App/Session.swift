import Foundation
import SwiftData

/// Everything that exists *because* an account is signed in.
///
/// One session per account. Nothing here is a singleton, which is what makes multiple
/// accounts a UI problem later rather than an architecture problem.
struct Session: Sendable {
    let account: Account
    let client: OCSClient
    let store: TalkStore

    let conversations: ConversationService
    let chat: ChatService
    let reactions: ReactionService
    let capabilities: CapabilityService
    let participants: ParticipantService
    let directory: DirectoryService
    let sharedItems: SharedItemsService
    let attachments: AttachmentService
    let messageSearch: MessageSearchService
    let polls: PollService

    let conversationSync: ConversationSyncEngine
    let chatSync: ActiveChatSyncEngine

    var capabilitySnapshot: TalkCapabilities { account.capabilities }

    init(account: Account, credentials: Credentials, transport: any HTTPTransport, store: TalkStore) {
        self.account = account
        self.store = store

        let client = OCSClient(server: account.server, credentials: credentials, transport: transport)
        self.client = client

        conversations = ConversationService(client: client)
        chat = ChatService(client: client)
        reactions = ReactionService(client: client, currentUserID: account.userID)
        capabilities = CapabilityService(client: client)
        participants = ParticipantService(client: client)
        directory = DirectoryService(client: client)
        sharedItems = SharedItemsService(client: client)
        messageSearch = MessageSearchService(client: client)
        polls = PollService(client: client)
        attachments = AttachmentService(
            server: account.server,
            credentials: credentials,
            userID: account.userID,
            transport: transport,
            client: client
        )

        conversationSync = ConversationSyncEngine(service: conversations)
        chatSync = ActiveChatSyncEngine(chat: chat, conversations: conversations)
    }

    func shutdown() async {
        await conversationSync.stop()
        await chatSync.stop()
    }
}

/// Process-wide services that exist whether or not anyone is signed in.
@MainActor
final class AppDependencies {
    let transport: any HTTPTransport
    let credentialStore: any CredentialStore
    let authentication: AuthenticationService
    let network: any NetworkMonitoring
    let modelContainer: ModelContainer
    let store: TalkStore
    let preferences: Preferences

    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let device = ProcessInfo.processInfo.hostName
        // This string becomes the app password's name in the user's security settings, so
        // it has to identify both the app and which Mac it came from.
        return "kvidr \(version) (\(device))"
    }()

    init(inMemory: Bool = false) {
        transport = URLSessionTransport(userAgent: Self.userAgent)
        credentialStore = KeychainStore()
        preferences = Preferences()
        authentication = AuthenticationService(
            transport: transport,
            credentialStore: credentialStore,
            userAgent: Self.userAgent,
            // Read on demand: `UserDefaults` is thread-safe, and the setting can be toggled
            // while the app is running.
            isInsecureHTTPAllowed: {
                UserDefaults.standard.bool(forKey: Preferences.allowInsecureLocalServersKey)
            }
        )
        network = SystemNetworkMonitor()

        do {
            modelContainer = try ModelContainer.talkContainer(inMemory: inMemory)
        } catch {
            // A corrupt or unreadable cache must not stop the app from launching: fall back
            // to memory and refill from the server.
            Log.persistence.error("Couldn’t open the on-disk cache, continuing in memory: \(error.localizedDescription)")
            do {
                modelContainer = try ModelContainer(
                    for: Schema(CacheSchema.models),
                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
                )
            } catch {
                // Nothing left to fall back to: a schema that cannot be opened in memory
                // is a programming error in the schema itself, not a runtime condition.
                fatalError("The cache schema could not be opened even in memory: \(error)")
            }
        }
        store = TalkStore(modelContainer: modelContainer)
    }

    func makeSession(account: Account) throws -> Session {
        guard let credentials = try credentialStore.credentials(for: account.id) else {
            throw TalkError.notAuthenticated
        }
        return Session(account: account, credentials: credentials, transport: transport, store: store)
    }
}
