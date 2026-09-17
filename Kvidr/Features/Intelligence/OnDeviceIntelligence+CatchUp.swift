import FoundationModels

/// Summarising what you missed.
extension OnDeviceIntelligence {
    /// Four lines about a pile of unread messages, or nothing.
    ///
    /// `nil` rather than an apology when the model declines: the marker simply says it
    /// couldn't, and the messages are right there to be read the ordinary way.
    func catchUp(on transcript: String, for me: String) async -> CatchUp? {
        guard !transcript.isEmpty else { return nil }

        guard let summary = await answer(
            CatchUpSummary.self,
            purpose: .catchUp,
            instructions: Self.catchUpInstructions,
            prompt: """
            The reader is \(me). These are the messages they haven't read yet, oldest first:

            \(transcript)
            """
        ) else { return nil }

        let points = summary.points
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)

        let headline = summary.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !points.isEmpty, !headline.isEmpty else { return nil }

        return CatchUp(
            headline: headline,
            points: Array(points),
            needsYou: summary.needsYou,
            messageCount: transcript.split(separator: "\n").count
        )
    }

    private static let catchUpInstructions = """
    You summarise unread work-chat messages for the person who missed them.

    Rules:
    - Write in the language the conversation is in. Danish in, Danish out.
    - One headline of at most ten words, then two to four points, each one sentence.
    - Say who did or asked what. "Salina needs the beach photos" is useful; "someone asked \
    for photos" is not.
    - Report only what was actually said. Never guess at what someone meant, never resolve \
    a disagreement, and never invent an outcome the messages don't state.
    - Decisions and questions first. Small talk last, or not at all.
    - Set needsYou when somebody is waiting on the reader specifically — a direct question, \
    a request, or something assigned to them.
    - Never comment on anybody's health, beliefs, performance or private life, even when \
    the messages do. Leave it out of the summary rather than paraphrasing it.
    """
}

/// What the model answers with when asked to catch someone up.
@Generable
private struct CatchUpSummary {
    @Guide(description: "The gist in at most ten words, in the conversation's language.")
    var headline: String

    @Guide(description: "Two to four things that happened, each one sentence, naming who said or asked what.")
    var points: [String]

    @Guide(description: "True when somebody is waiting on the reader for something.")
    var needsYou: Bool
}
