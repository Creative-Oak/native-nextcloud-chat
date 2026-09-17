import Foundation
import Observation

/// What you missed, in four lines, above the messages you missed.
///
/// The one feature here that is worth a whole model on its own: forty unread messages in a
/// busy room is the daily problem a work chat client actually has, and no table is ever
/// going to solve it.
///
/// It is asked for, not assumed. Opening a conversation does **not** start an inference —
/// the unread marker offers it and you click. Summarising forty messages the moment a room
/// is opened would be slow, presumptuous, and wrong most of the time, because most of the
/// time you are going to read them anyway.
@MainActor
@Observable
final class CatchUpModel {
    enum State: Equatable {
        case idle
        case working
        case ready(CatchUp)
        /// The model declined — a guardrail, or it went away. Said plainly, once.
        case failed
    }

    private(set) var state: State = .idle

    @ObservationIgnored var intelligence: OnDeviceIntelligence?
    @ObservationIgnored var isEnabled = true
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The conversation the state belongs to, so one room's summary can't be shown over
    /// another's messages.
    @ObservationIgnored private var token: String?

    /// Below this, reading them is quicker than summarising them.
    static let threshold = 6

    func canOffer(for model: ChatModel) -> Bool {
        guard isEnabled, intelligence?.isReady == true, !model.conversation.isSensitive else { return false }
        return model.unreadForCatchUp.count >= Self.threshold
    }

    /// Reopening the same conversation keeps a summary that is still about the same
    /// messages; anything else starts clean.
    func prepare(for model: ChatModel) {
        guard token != model.token else { return }
        task?.cancel()
        token = model.token
        state = .idle
    }

    func summarise(_ model: ChatModel) {
        guard let intelligence, intelligence.isReady else { return }
        let messages = model.unreadForCatchUp
        guard messages.count >= 2 else { return }

        task?.cancel()
        state = .working
        let token = model.token
        let transcript = Self.transcript(of: messages)
        let me = model.session.account.resolvedDisplayName

        task = Task { [weak self] in
            let summary = await intelligence.catchUp(on: transcript, for: me)
            guard !Task.isCancelled, let self, self.token == token else { return }
            if let summary, !summary.points.isEmpty {
                self.state = .ready(summary)
            } else {
                self.state = .failed
            }
        }
    }

    func dismiss() {
        task?.cancel()
        state = .idle
    }

    /// Named lines, oldest first, trimmed. Who said a thing is half of what a summary is
    /// for — "somebody needs the invoice" is useless, "Salina needs the invoice" is not.
    private static func transcript(of messages: [Message]) -> String {
        messages
            .map { "\($0.actor.resolvedDisplayName): \($0.text.prefix(400))" }
            .joined(separator: "\n")
    }
}

/// A summary of what was missed.
struct CatchUp: Sendable, Equatable {
    /// One line: the gist.
    var headline: String
    /// Up to four things that happened, each a sentence.
    var points: [String]
    /// Whether somebody is waiting on this user for something.
    var needsYou: Bool
    /// How many messages went into it, for the caption.
    var messageCount: Int
}

extension ChatModel {
    /// The unread messages worth summarising: everything from the marker on, other
    /// people's, with words in them.
    ///
    /// Capped at sixty. Past that the summary stops being about what you missed and starts
    /// being about the conversation, and the model's context is better spent on detail in
    /// the recent ones than on completeness in the old ones.
    var unreadForCatchUp: [Message] {
        guard let first = firstUnreadMessageID else { return [] }
        let unread = messages
            .filter { $0.messageID >= first && !$0.isSystem && !$0.isDeleted && !isFromMe($0) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(unread.suffix(60))
    }
}
