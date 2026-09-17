import FoundationModels

/// Deciding which of a handful of messages are waiting on the reader.
extension OnDeviceIntelligence {
    /// The tokens of the conversations that want something from this user.
    ///
    /// Numbered in, numbers out: the model never sees or returns a conversation token, only
    /// a position in the list it was given. A token is an identifier the app trusts, and
    /// nothing a model wrote should ever be one.
    func triage(_ candidates: [AttentionCandidate]) async -> Set<String> {
        guard isReady, !candidates.isEmpty else { return [] }

        let list = candidates.enumerated().map { index, candidate in
            let room = candidate.isGroup ? "in the group “\(candidate.room)”" : "in a one-to-one"
            return "\(index + 1). \(candidate.who), \(room): \(candidate.text)"
        }.joined(separator: "\n")

        guard let verdict = await answer(
            TriageVerdict.self,
            purpose: .triage,
            instructions: Self.triageInstructions,
            prompt: """
            The most recent unread message in each of \(candidates.count) conversations:

            \(list)

            Which of these are waiting on the reader?
            """
        ) else { return [] }

        // Out-of-range numbers are dropped rather than clamped: a number that isn't on the
        // list is the model having lost its place, and guessing which one it meant would be
        // worse than ignoring it.
        var tokens: Set<String> = []
        for number in verdict.waitingOnReader {
            guard number >= 1, number <= candidates.count else { continue }
            tokens.insert(candidates[number - 1].token)
        }
        return tokens
    }

    private static let triageInstructions = """
    You decide which work-chat messages are waiting on the reader for something.

    A message is waiting on the reader when it asks them a question, asks them to do \
    something, or says something is blocked on them.

    It is NOT waiting on them when it is an announcement, a status update, somebody \
    thinking out loud, an answer to something already settled, or a question plainly aimed \
    at somebody else in a group.

    Messages are often in Danish.

    Answer with the numbers of the messages that are waiting on the reader, and nothing \
    else. An empty answer is a good answer — most messages are not waiting on anybody, and \
    a list that marks everything marks nothing.
    """
}

/// What the model answers with when asked which messages need the reader.
@Generable
private struct TriageVerdict {
    @Guide(description: "The numbers of the messages that are waiting on the reader. Empty when none are.")
    var waitingOnReader: [Int]
}
