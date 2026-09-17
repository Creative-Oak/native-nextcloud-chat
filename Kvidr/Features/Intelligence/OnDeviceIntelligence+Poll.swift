import FoundationModels

/// Turning a conversation that is going in circles into a question with options.
extension OnDeviceIntelligence {
    /// A question and its options, read out of what people have been saying — or nothing.
    ///
    /// Only ever a *draft*. It lands in the poll sheet's fields for the user to correct and
    /// post, because a poll is a thing with your name on it that everybody in the room
    /// sees, and no model gets to send one of those.
    func draftPoll(from transcript: String) async -> PollDraft? {
        guard isReady, !transcript.isEmpty else { return nil }

        guard let draft = await answer(
            PollDraftAnswer.self,
            purpose: .poll,
            instructions: Self.pollInstructions,
            prompt: """
            The conversation so far, oldest first:

            \(transcript)

            What are they trying to decide?
            """
        ) else { return nil }

        let question = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        let options = draft.options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 100 }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(5)

        // A poll needs a question and at least two things to choose between. Anything less
        // is the model having found no decision in the conversation, which is a fair answer.
        guard !question.isEmpty, question.count <= 200, options.count >= 2 else { return nil }
        return PollDraft(question: question, options: Array(options))
    }

    private static let pollInstructions = """
    You read a work-chat conversation and write the poll that would settle it.

    Rules:
    - Write in the language the conversation is in.
    - One question, under fifteen words, phrased as the group would ask it.
    - Two to five options, each a few words. They must be the options the people in the \
    conversation actually raised.
    - Never invent an option nobody suggested, and never add "other" or "none of the above".
    - If the conversation isn't trying to decide anything, answer with an empty question \
    and no options. That is a good answer and happens often.
    - Never make a poll about a person — their work, their behaviour, or anything about \
    them. Only about a decision the group is taking.
    """
}

/// A poll the user has not agreed to yet.
struct PollDraft: Sendable, Equatable {
    var question: String
    var options: [String]
}

/// What the model answers with when asked to draft a poll.
@Generable
private struct PollDraftAnswer {
    @Guide(description: "The decision being taken, as a question under fifteen words. Empty when the conversation isn't deciding anything.")
    var question: String

    @Guide(description: "Two to five options, each a few words, taken from what people actually suggested.")
    var options: [String]
}
