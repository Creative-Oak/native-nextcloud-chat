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
    let reminders: ReminderService
    let pins: PinService
    let threads: ThreadService
    let calls: CallService
    let breakoutRooms: BreakoutRoomService
    let bots: BotService
    let tags: ConversationTagService
    let serverNotifications: NotificationsService
    let scheduledMessages: ScheduledMessageService
    let absences: AbsenceService
    /// The live connection to the High Performance Backend. Started by the app.
    let signaling: SignalingConnection
    let profile: ProfileService
    let userStatus: UserStatusService
    let profileLinks: ProfileLinks

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
        reminders = ReminderService(client: client)
        pins = PinService(client: client)
        threads = ThreadService(client: client)
        calls = CallService(client: client)
        breakoutRooms = BreakoutRoomService(client: client)
        bots = BotService(client: client)
        tags = ConversationTagService(client: client)
        serverNotifications = NotificationsService(client: client)
        scheduledMessages = ScheduledMessageService(client: client)
        absences = AbsenceService(client: client)
        let signalingSettings = SignalingSettingsService(client: client)
        signaling = SignalingConnection(
            settings: { () throws(TalkError) -> SignalingSettings in try await signalingSettings.settings() },
            authURL: account.server.url(path: Endpoint.signalingBackend)
        )
        profile = ProfileService(
            server: account.server,
            credentials: credentials,
            userID: account.userID,
            transport: transport,
            client: client
        )
        userStatus = UserStatusService(client: client)
        profileLinks = ProfileLinks(server: account.server, userID: account.userID)
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
        await signaling.stop()
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
    /// The keys everything cached for an account is sealed with — the database, and the
    /// pictures kept as files beside it.
    let cacheKeyring: any CacheKeyring

    private static let version: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"

    /// Sent on every request, and deliberately says nothing about this Mac.
    ///
    /// The first thing the app does with an address is probe it, before the user has
    /// decided to trust anything, and a Mac's host name is commonly its owner's real name.
    /// A typosquatted address should not collect that from a single typo.
    static let userAgent: String = "kvidr/\(version)"

    /// Only the login flow sends this one. It becomes the app password's name in the
    /// user's Nextcloud security settings, so here the device name is the whole point —
    /// and by then the user has chosen this server and is signing in to it.
    static let loginUserAgent: String = "kvidr \(version) (\(ProcessInfo.processInfo.hostName))"

    init(inMemory: Bool = false) {
        transport = URLSessionTransport(userAgent: Self.userAgent)
        credentialStore = KeychainStore()
        preferences = Preferences()
        authentication = AuthenticationService(
            transport: transport,
            credentialStore: credentialStore,
            userAgent: Self.loginUserAgent,
            // Read on demand: `UserDefaults` is thread-safe, and the setting can be toggled
            // while the app is running.
            isInsecureHTTPAllowed: {
                UserDefaults.standard.bool(forKey: Preferences.allowInsecureLocalServersKey)
            }
        )
        network = SystemNetworkMonitor()
        // One per process, shared by the migration that may rebuild the store at launch and
        // the store that reads it afterwards.
        let cacheKeyring = KeychainCacheKeyring()
        self.cacheKeyring = cacheKeyring

        do {
            modelContainer = try ModelContainer.talkContainer(inMemory: inMemory, keyring: cacheKeyring)
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
        store = TalkStore(modelContainer: modelContainer, keyring: cacheKeyring)
    }

    func makeSession(account: Account) throws -> Session {
        guard let credentials = try credentialStore.credentials(for: account.id) else {
            throw TalkError.notAuthenticated
        }
        return Session(account: account, credentials: credentials, transport: transport, store: store)
    }
}
