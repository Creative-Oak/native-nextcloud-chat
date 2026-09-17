import FoundationModels

/// Reading a long spoken message.
extension OnDeviceIntelligence {
    /// One sentence about a recording, and anything it asked for.
    func gist(ofSpokenMessage transcript: String) async -> VoiceGist? {
        guard isReady, transcript.count >= 100 else { return nil }

        guard let read = await answer(
            SpokenGist.self,
            purpose: .voice,
            instructions: Self.voiceInstructions,
            // Speech recognition mangles words, and the model should be told so rather than
            // left to treat a mis-heard name as a fact.
            prompt: """
            A transcript of a spoken message. It was written out by speech recognition, so \
            some words may be wrong:

            \(transcript.prefix(4000))
            """
        ) else { return nil }

        let summary = read.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 200 else { return nil }

        let actions = read.actions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
            .prefix(4)

        return VoiceGist(summary: summary, actions: Array(actions))
    }

    private static let voiceInstructions = """
    You read the transcript of a spoken message and say what it came to.

    Rules:
    - Write in the language it was spoken in.
    - summary: one sentence, under twenty words, saying what the message was about.
    - actions: anything the speaker asked for or agreed to do, one short line each. Empty \
    when they asked for nothing, which is most messages.
    - Only what was said. Speech recognition makes mistakes; where a word is plainly garbled, \
    leave it out rather than guessing what it was.
    - Never invent a deadline, a number or a name that isn't in the transcript.
    - Never comment on how somebody sounded, or on their health, mood or private life.
    """
}

/// What the model answers with when asked about a recording.
@Generable
private struct SpokenGist {
    @Guide(description: "One sentence under twenty words saying what the message was about, in the language spoken.")
    var summary: String

    @Guide(description: "Anything the speaker asked for or agreed to do, one short line each. Empty when there is nothing.")
    var actions: [String]
}
