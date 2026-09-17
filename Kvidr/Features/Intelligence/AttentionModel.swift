import Foundation
import Observation

/// Which conversations in the sidebar are actually waiting on you.
///
/// The table decides first and instantly, from the last message the sidebar already holds —
/// no request, no model, right on the first paint. Only the conversations it can't call
/// either way go to the on-device model, and they go **in one prompt, together**: a sidebar
/// is one question ("which of these need me?"), not twenty.
///
/// The cache is keyed by message id, so a conversation is judged once per new message
/// rather than once per sidebar redraw.
@MainActor
@Observable
final class AttentionModel {
    /// Conversations whose newest unread message wants something from this user.
    private(set) var needsYou: Set<String> = []

    @ObservationIgnored var intelligence: OnDeviceIntelligence?
    @ObservationIgnored var isEnabled = true

    /// The verdict already reached for a given message, by "<token>/<message id>".
    @ObservationIgnored private var judged: [String: Bool] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// At most this many go to the model at once. Beyond it the sidebar is a wall anyway,
    /// and the table's answer stands for the rest.
    private static let batchLimit = 12

    /// Called whenever the conversation list changes.
    func update(with conversations: [Conversation], currentUserID: String) {
        guard isEnabled else {
            needsYou = []
            return
        }

        var decided: Set<String> = []
        var toAsk: [Conversation] = []

        for conversation in conversations where Self.isCandidate(conversation, currentUserID: currentUserID) {
            guard let message = conversation.lastMessage else { continue }
            let key = "\(conversation.token)/\(message.messageID)"

            if let remembered = judged[key] {
                if remembered { decided.insert(conversation.token) }
                continue
            }

            switch AttentionScanner.read(message.text, mentionsYou: conversation.unreadMention) {
            case .asksYou:
                judged[key] = true
                decided.insert(conversation.token)
            case .ignorable:
                judged[key] = false
            case .unclear:
                toAsk.append(conversation)
            }
        }

        needsYou = decided
        forgetConversationsThatWent(in: conversations)

        guard intelligence?.isReady == true, !toAsk.isEmpty else { return }
        ask(about: Array(toAsk.prefix(Self.batchLimit)))
    }

    /// Opening a conversation answers the question, whether or not you answer the message:
    /// the mark is about unread, and this one isn't any more. Without this the orange stays
    /// on screen until the next sync tells the sidebar what it already knows.
    func markHandled(_ token: String) {
        needsYou.remove(token)
    }

    /// One prompt for the whole sidebar.
    private func ask(about conversations: [Conversation]) {
        guard let intelligence else { return }
        let candidates = conversations.compactMap { conversation -> AttentionCandidate? in
            guard let message = conversation.lastMessage else { return nil }
            return AttentionCandidate(
                token: conversation.token,
                messageID: message.messageID,
                who: message.actor.resolvedDisplayName,
                room: conversation.displayName,
                isGroup: !conversation.isOneToOne,
                text: String(message.text.prefix(300))
            )
        }
        guard !candidates.isEmpty else { return }

        task?.cancel()
        task = Task { [weak self] in
            // A moment's grace: the sidebar changes in bursts while a sync lands, and each
            // burst would otherwise start its own inference.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let asking = await intelligence.triage(candidates)
            guard !Task.isCancelled, let self else { return }

            for candidate in candidates {
                self.judged["\(candidate.token)/\(candidate.messageID)"] = asking.contains(candidate.token)
            }
            self.needsYou.formUnion(asking)
        }
    }

    /// Only an unread conversation from somebody else can be waiting on you, and only one
    /// with words in it — a shared file is not a question.
    private static func isCandidate(_ conversation: Conversation, currentUserID: String) -> Bool {
        guard conversation.hasUnread, !conversation.isArchived, !conversation.isSensitive else { return false }
        guard let message = conversation.lastMessage else { return false }
        guard !message.isSystem, !message.isDeleted else { return false }
        // Your own last message can't be waiting on you, however the unread count reads
        // in the moment after you sent it.
        guard !(message.actor.kind == .users && message.actor.id == currentUserID) else { return false }
        return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keeps the cache from growing for the life of the session.
    private func forgetConversationsThatWent(in conversations: [Conversation]) {
        guard judged.count > 200 else { return }
        let live = Set(conversations.map(\.token))
        judged = judged.filter { key, _ in
            live.contains(String(key.prefix(while: { $0 != "/" })))
        }
    }
}

/// One conversation put to the model, in the batch.
struct AttentionCandidate: Sendable {
    var token: String
    var messageID: Int
    var who: String
    /// The conversation's name, for telling a group question from a direct one.
    var room: String
    var isGroup: Bool
    var text: String
}
