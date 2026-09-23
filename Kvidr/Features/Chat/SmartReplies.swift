import Foundation
import FoundationModels
import Observation

/// Replies you might send to the newest message, written on this Mac by Apple's language
/// model — three short ones, in the conversation's language, shown over the field while it's
/// empty. Clicking one puts it in the field, to send as it is or to change first.
@MainActor
@Observable
final class SmartReplies {
    /// For the message they answer; empty while there are none.
    private(set) var suggestions: [String] = []
    private(set) var messageID: Int?

    private var task: Task<Void, Never>?

    @Generable
    struct Replies {
        @Guide(description: "Three different short replies the user could send next: one agreeing or answering, one asking something back, one declining or putting it off — whichever fit.", .count(3))
        var replies: [String]
    }

    private static let instructions = """
        You suggest replies in a chat app. You are given the latest messages of a conversation \\
        and the name of the person you write for. Suggest what that person could send next. \\
        Each reply is at most eight words, in the language the conversation is in, casual and \\
        natural, with no emoji unless the others use them. Never invent facts, dates or promises \\
        beyond what the messages say.
        """

    /// Asks for replies to `messageID`, once — the same message again keeps what there is.
    func suggest(for messageID: Int, lines: [SummaryInput.Line], me: String) {
        guard messageID != self.messageID, case .available = UnreadSummary.availability else { return }
        self.messageID = messageID
        suggestions = []
        task?.cancel()
        let (transcript, included) = SummaryInput.transcript(Array(lines.suffix(10)), budget: 1_800)
        guard included > 0 else { return }
        task = Task { [weak self] in
            // A moment's pause: messages often come in twos and threes.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "You write for \(me). The latest messages, oldest first:\n\n\(transcript)"
            guard let response = try? await session.respond(to: prompt, generating: Replies.self),
                  !Task.isCancelled, self?.messageID == messageID
            else { return }
            self?.suggestions = response.content.replies
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))) }
                .filter { !$0.isEmpty }
        }
    }

    /// Typing, sending, or the newest message being this user's own: none now.
    func clear() {
        task?.cancel()
        suggestions = []
    }
}
