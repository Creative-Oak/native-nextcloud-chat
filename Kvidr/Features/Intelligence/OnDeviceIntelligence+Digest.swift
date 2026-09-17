import FoundationModels

/// Saying what a pile of waiting conversations adds up to.
extension OnDeviceIntelligence {
    /// One line for a notification body, or nothing.
    ///
    /// Short on purpose: a banner shows about two lines, and a summary that gets cut off
    /// mid-sentence is worse than the list of names it replaced.
    func notificationDigest(of lines: [String]) async -> String? {
        guard isReady, lines.count >= 2 else { return nil }

        guard let digest = await answer(
            NotificationDigestText.self,
            purpose: .notifications,
            instructions: Self.digestInstructions,
            prompt: """
            The newest message in each conversation that is waiting:

            \(lines.joined(separator: "\n"))
            """
        ) else { return nil }

        let text = digest.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 160 else { return nil }
        return text
    }

    private static let digestInstructions = """
    You write the one line a Mac notification shows when several chat conversations are \
    waiting at once.

    Rules:
    - One sentence, at most twenty words. It has to fit in a banner.
    - Write in the language the messages are in.
    - Name the people. "Heine needs the invoice; Salina asked about Friday" is the shape.
    - Lead with anything that is a question or a request; leave chat out entirely if there \
    isn't room.
    - Report only what was said. Never guess at urgency, and never invent a deadline.
    - Never mention anybody's health, beliefs or private life, even when the messages do.
    """
}

/// What the model answers with when asked to sum up a burst of notifications.
@Generable
private struct NotificationDigestText {
    @Guide(description: "One sentence of at most twenty words, naming who is waiting and what for.")
    var line: String
}
