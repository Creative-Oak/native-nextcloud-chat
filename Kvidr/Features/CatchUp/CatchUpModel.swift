import Foundation
import FoundationModels
import Observation

/// Catching up on everything at once: each conversation with unread messages in a sentence
/// or two, what's asked of you in it, and any dates — written on this Mac by Apple's language
/// model, one conversation after another, the ones that need you first. Reading them here
/// marks nothing as read.
@MainActor
@Observable
final class CatchUpModel {
    struct Entry: Identifiable, Equatable {
        var id: String { conversation.token }
        let conversation: Conversation
        var state: State = .waiting

        enum State: Equatable {
            case waiting
            case reading
            case done(Digest)
            case failed(String)
        }
    }

    @Generable
    struct Digest: Equatable {
        @Guide(description: "One or two sentences on what happened, in the language of the messages.")
        var gist: String
        @Guide(description: "Questions or requests aimed at the reader, each short, with who asked. Empty if none.", .maximumCount(3))
        var forYou: [String]
        @Guide(description: "Dates, times or deadlines mentioned, each with what it's for. Empty if none.", .maximumCount(3))
        var dates: [String]
        @Guide(description: "How much this needs the reader: 0 nothing, 1 worth a look, 2 needs an answer.", .range(0...2))
        var urgency: Int
    }

    private(set) var entries: [Entry] = []
    private(set) var isRunning = false
    /// When it was last written.
    private(set) var writtenAt: Date?

    /// At most this many conversations: the most recently active.
    static let maximumConversations = 12
    /// Of each, at most this many of the newest unread messages.
    static let messagesPerConversation = 40

    @ObservationIgnored private let session: Session
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private lazy var parser = MessageContentParser(
        currentUserID: session.account.userID,
        markdownEnabled: session.capabilitySnapshot.supportsMarkdown
    )

    init(session: Session) {
        self.session = session
    }

    private static let instructions = """
        You help someone catch up on a chat conversation they haven't read. You get its unread \\
        messages and the reader's name. Be brief and concrete; use only what the messages say. \\
        Write everything in the language the messages are in.
        """

    /// Starts over with `conversations` — those with unread messages, most recent first.
    func run(over conversations: [Conversation]) {
        task?.cancel()
        let picked = conversations
            .filter { $0.unreadMessages > 0 && !$0.isArchived && !$0.isBreakoutRoom && $0.notificationLevel != .never }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(Self.maximumConversations)
        entries = picked.map { Entry(conversation: $0) }
        guard case .available = UnreadSummary.availability else {
            for index in entries.indices { entries[index].state = .failed(Self.unavailableReason) }
            return
        }
        isRunning = true
        writtenAt = Date()
        task = Task { [weak self] in
            for conversation in picked {
                guard let self, !Task.isCancelled else { return }
                await self.digest(conversation)
            }
            self?.isRunning = false
            self?.sortByNeed()
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }

    private static var unavailableReason: String {
        if case .notYet(let reason) = UnreadSummary.availability { return reason }
        return String(localized: "Catching up needs Apple Intelligence, which this Mac doesn’t have.")
    }

    private func digest(_ conversation: Conversation) async {
        update(conversation.token) { $0.state = .reading }
        do throws(TalkError) {
            let batch = try await session.chat.history(token: conversation.token, limit: min(conversation.unreadMessages, Self.messagesPerConversation) + 1)
            let unread = batch.messages.filter { $0.messageID > conversation.lastReadMessageID }
            let lines = SummaryInput.lines(from: unread, startingAt: 0) { self.parser.parse($0).preview }
            let (transcript, included) = SummaryInput.transcript(lines, budget: 4_500)
            guard included > 0 else {
                update(conversation.token) { $0.state = .failed(String(localized: "Nothing to read — only system messages.", comment: "Catch Up: a conversation whose unread messages are all system messages")) }
                return
            }
            let model = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
                The reader is \(session.account.displayName). Unread messages in “\(conversation.displayName)”, oldest first:

                \(transcript)
                """
            do {
                let response = try await model.respond(to: prompt, generating: Digest.self)
                update(conversation.token) { $0.state = .done(response.content) }
                sortByNeed()
            } catch {
                update(conversation.token) { $0.state = .failed(String(localized: "Apple Intelligence couldn’t read this one.", comment: "Catch Up: the language model failed on this conversation")) }
            }
        } catch {
            update(conversation.token) { $0.state = .failed(String(localized: "Couldn’t get the messages: \(error.userMessage)", comment: "Catch Up: %@ is the error")) }
        }
    }

    /// What needs an answer first; a mention counts; then the newest. Ones still being read
    /// stay where they are, at the end.
    private func sortByNeed() {
        func need(_ entry: Entry) -> Int {
            guard case .done(let digest) = entry.state else { return -1 }
            return digest.urgency * 2 + (entry.conversation.unreadMention ? 1 : 0)
        }
        entries.sort { lhs, rhs in
            let (l, r) = (need(lhs), need(rhs))
            return l != r ? l > r : lhs.conversation.lastActivity > rhs.conversation.lastActivity
        }
    }

    private func update(_ token: String, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == token }) else { return }
        change(&entries[index])
    }
}
