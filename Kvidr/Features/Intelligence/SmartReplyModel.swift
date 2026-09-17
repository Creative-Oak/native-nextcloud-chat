import Foundation
import Observation

/// Two or three replies you could send without typing, above the message field.
///
/// The row in Messages' keyboard, where a Mac has no keyboard to put it in — so it sits
/// where the mention list sits, above the field, and disappears the moment you type. It
/// asks only when there is a question worth answering: somebody else spoke last, the field
/// is empty, and you are not in the middle of a reply or an edit.
@MainActor
@Observable
final class SmartReplyModel {
    private(set) var replies: [String] = []
    private(set) var isThinking = false

    @ObservationIgnored var intelligence: OnDeviceIntelligence?
    @ObservationIgnored var isEnabled = true

    /// The message the replies on screen answer. Nothing is asked twice for the same one.
    @ObservationIgnored private var answering: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Called whenever the transcript or the draft changes.
    func update(for model: ChatModel) {
        guard isEnabled, let intelligence, intelligence.isReady else {
            clear()
            return
        }
        // Nothing to suggest over: a draft in progress, a reply being composed, an edit, or
        // a conversation whose content is meant to stay off the screen.
        guard model.draftText.isEmpty, model.replyingTo == nil, model.editing == nil,
              model.sendLater == nil, !model.conversation.isSensitive,
              model.conversation.canPostMessages
        else {
            clear()
            return
        }
        guard let latest = model.messages.last,
              !model.isFromMe(latest), !latest.isSystem, !latest.isDeleted,
              !latest.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latest.messageID > 0
        else {
            clear()
            return
        }
        guard answering != latest.messageID else { return }

        answering = latest.messageID
        replies = []
        task?.cancel()

        let transcript = Self.transcript(of: model)
        let ownMessages = Self.ownMessages(of: model)
        isThinking = true
        task = Task { [weak self] in
            // A moment's wait, so a burst of arriving messages is answered once, at the end.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let suggestions = await intelligence.replies(to: transcript, inTheStyleOf: ownMessages)
            guard !Task.isCancelled, let self, self.answering == latest.messageID else { return }
            self.replies = suggestions
            self.isThinking = false
        }
    }

    /// Used one, or typed instead: either way the row has served its purpose.
    func dismiss() {
        task?.cancel()
        replies = []
        isThinking = false
    }

    func clear() {
        task?.cancel()
        task = nil
        answering = nil
        replies = []
        isThinking = false
    }

    // MARK: - What the model is told

    /// The last few turns, as lines. Names rather than "user"/"assistant", because who
    /// said what is most of what decides an answer in a group.
    private static func transcript(of model: ChatModel) -> String {
        model.messages
            .filter { !$0.isSystem && !$0.isDeleted && !$0.text.isEmpty }
            .suffix(6)
            .map { message in
                let name = model.isFromMe(message) ? "Me" : message.actor.resolvedDisplayName
                return "\(name): \(message.text.prefix(300))"
            }
            .joined(separator: "\n")
    }

    /// How this user writes, from what they have written here.
    private static func ownMessages(of model: ChatModel) -> [String] {
        let mine = model.messages
            .filter { model.isFromMe($0) && !$0.isSystem && !$0.isDeleted }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
        return Array(mine.suffix(6))
    }
}
