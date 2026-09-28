import AppIntents
import Foundation

/// How App Intents reach the app's state. Set when the window appears.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    weak var app: AppModel?

    /// The app, once it's signed in and has its conversations — waking it if need be.
    func readyApp() async throws -> AppModel {
        guard let app, await app.waitUntilReady() else { throw IntentError.notSignedIn }
        return app
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case notFound
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: "kvidr isn’t signed in to Nextcloud."
        case .notFound: "kvidr couldn’t find that conversation."
        case .failed(let reason): "\(reason)"
        }
    }
}

/// A conversation, as Shortcuts and Siri see it.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = ConversationQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ conversation: Conversation) {
        id = conversation.token
        name = conversation.displayName
    }
}

struct ConversationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        try await MainActor.run {
            guard let list = IntentBridge.shared.app?.conversationList else { return [] }
            return identifiers.compactMap { list[$0] }.map(ConversationEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        let app = try await IntentBridge.shared.readyApp()
        return await MainActor.run {
            app.conversationList?.index.filtered(by: string).filter { !$0.isBreakoutRoom }.prefix(20).map(ConversationEntity.init) ?? []
        }
    }

    /// The most recently active, for the picker.
    func suggestedEntities() async throws -> [ConversationEntity] {
        let app = try await IntentBridge.shared.readyApp()
        return await MainActor.run {
            (app.conversationList?.index.allConversations ?? [])
                .filter { !$0.isBreakoutRoom && !$0.isArchived }
                .sorted { $0.lastActivity > $1.lastActivity }
                .prefix(20)
                .map(ConversationEntity.init)
        }
    }
}

struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in kvidr.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$conversation)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.shared.readyApp()
        app.selectedToken = conversation.id
        return .result()
    }
}

/// Sends straight away — Shortcuts and Siri are run by the user, so this is them sending.
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Sends a message to a conversation in kvidr.")

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$conversation)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentError.failed(String(localized: "There’s nothing to send.")) }
        let app = try await IntentBridge.shared.readyApp()
        do throws(TalkError) {
            try await app.send(text, to: conversation.id)
        } catch {
            throw IntentError.failed(String(localized: "The message couldn’t be sent: \(error.userMessage)", comment: "Shortcuts error: %@ is the reason"))
        }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

struct JoinCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Call or Join Call"
    static let description = IntentDescription("Starts a call in a conversation in kvidr, or joins the one going on.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Call \(\.$conversation)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.shared.readyApp()
        guard app.activeCall == nil else { throw IntentError.failed(String(localized: "You’re already in a call.")) }
        app.selectedToken = conversation.id
        for _ in 0..<30 where app.chat?.token != conversation.id {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard app.chat?.token == conversation.id else { throw IntentError.notFound }
        await app.joinCall()
        return .result()
    }
}

struct CatchUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Catch Up"
    static let description = IntentDescription("Opens kvidr's summary of every unread conversation.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try await IntentBridge.shared.readyApp()
        app.selectedToken = CatchUpToken.value
        return .result()
    }
}

/// Siri phrases, and the actions Shortcuts and Spotlight offer without setting anything up.
struct KvidrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Send a message with \(.applicationName)",
                "Message \(\.$conversation) with \(.applicationName)"
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: [
                "Open \(\.$conversation) in \(.applicationName)",
                "Show \(\.$conversation) in \(.applicationName)"
            ],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: JoinCallIntent(),
            phrases: [
                "Call \(\.$conversation) with \(.applicationName)",
                "Join the call in \(\.$conversation) with \(.applicationName)"
            ],
            shortTitle: "Call",
            systemImageName: "phone"
        )
        AppShortcut(
            intent: CatchUpIntent(),
            phrases: [
                "Catch up in \(.applicationName)",
                "What did I miss in \(.applicationName)"
            ],
            shortTitle: "Catch Up",
            systemImageName: "list.bullet.clipboard"
        )
    }
}
