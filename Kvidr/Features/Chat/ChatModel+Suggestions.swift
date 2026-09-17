import Foundation

/// The one-tap row under a message — what to offer, and what happens when it is tapped.
///
/// The offering is entirely local: `SuggestionScanner` reads the text, and that is all.
/// No model runs per message, on purpose. A chip that appears half a second after you have
/// read the message is worse than no chip at all, and a transcript that quietly runs an
/// inference for every bubble that scrolls past is not a transcript anybody should ship.
extension ChatModel {
    /// How far back chips are offered. Messages you have scrolled up to read are history;
    /// the ones at the bottom are the conversation you are in.
    private static let suggestionDepth = 8

    /// What this message is asking to become, if anything.
    func suggestions(for message: Message) -> [MessageSuggestion] {
        guard showsSuggestions, !conversation.isSensitive else { return [] }
        guard message.messageID > 0, !message.isSystem, !message.isDeleted, !message.isFileShare else { return [] }
        // Your own words, in a conversation with other people, don't need a chip: you were
        // there when they were written. Notes to yourself are the exception — that room is
        // for keeping things, which is what the chips do.
        guard !isFromMe(message) || conversation.isNoteToSelf else { return [] }
        guard isRecentEnoughForSuggestions(message) else { return [] }

        if let cached = suggestionCache[message.id] { return cached }
        let found = SuggestionScanner.suggestions(for: message.text)
        suggestionCache[message.id] = found
        return found
    }

    private func isRecentEnoughForSuggestions(_ message: Message) -> Bool {
        messages.suffix(Self.suggestionDepth).contains { $0.id == message.id }
    }

    /// Whether a chip has already been acted on, so it can say so instead of offering again.
    func isSuggestionUsed(_ suggestion: MessageSuggestion, on message: Message) -> Bool {
        usedSuggestions.contains(Self.key(suggestion, message))
    }

    func usedSuggestionKeys(for message: Message) -> Set<String> {
        let prefix = "\(message.id)/"
        return Set(usedSuggestions.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    /// A chip was clicked.
    ///
    /// - Parameters:
    ///   - reminders: where a reminder goes — the store decides Nextcloud, Apple, or both.
    ///   - noteToSelfToken: the user's own Note to self conversation, when the server has one.
    func activate(
        _ suggestion: MessageSuggestion,
        on message: Message,
        reminders: ReminderStore?,
        noteToSelfToken: String?
    ) {
        switch suggestion.kind {
        case .remind(let date):
            guard let reminders, reminders.canRemind else { return }
            reminders.remind(about: message, at: date)

        case .note:
            guard let noteToSelfToken else { return }
            keep(message, in: noteToSelfToken)
        }
        usedSuggestions.insert(Self.key(suggestion, message))
    }

    /// Sends a message on to the user's Note to self conversation, credited to whoever
    /// wrote it — the note is only useful if it still says who said it.
    private func keep(_ message: Message, in token: String) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = isFromMe(message)
            ? text
            : "\(message.actor.resolvedDisplayName) — \(conversation.displayName):\n\(text)"

        let service = session.chat
        Task { [weak self] in
            do throws(TalkError) {
                _ = try await service.send(token: token, message: note, replyTo: nil, replyToToken: nil, referenceID: nil)
            } catch {
                // The chip goes back to offering itself, which is the only honest thing for
                // it to do when the note never arrived.
                self?.usedSuggestions.remove("\(message.id)/note")
                self?.lastError = error
                Log.chat.warning("Couldn’t add to notes: \(error.userMessage)")
            }
        }
    }

    private static func key(_ suggestion: MessageSuggestion, _ message: Message) -> String {
        "\(message.id)/\(suggestion.id)"
    }
}
