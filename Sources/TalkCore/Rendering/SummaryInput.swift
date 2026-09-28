import Foundation

/// What an on-device summary of a conversation's unread messages is made from: the words,
/// each with who said them, trimmed to what the small model can take in.
enum SummaryInput {
    /// Fewer unread messages than this are quicker read than summarized, so no offer; asked
    /// for from the menu, any number goes.
    static let minimumMessages = 5
    /// Asked for with nothing unread: this many of the latest.
    static let recentMessages = 50
    /// Characters of transcript sent to the model. Its context is about 4 000 tokens, which
    /// also has to hold the instructions and the summary; Danish runs at roughly three
    /// characters a token, so this leaves room for both.
    static let characterBudget = 6_000
    /// A single message longer than this is cut, so one essay can't crowd out the rest.
    static let messageLimit = 600

    struct Line: Sendable, Equatable {
        var author: String
        var text: String
    }

    /// The messages worth summarizing from `firstID` on: people's words, not system events
    /// or deleted messages, each as its sender and a one-line rendering.
    static func lines(from messages: [Message], startingAt firstID: Int, text: (Message) -> String) -> [Line] {
        messages.compactMap { message in
            guard message.messageID >= firstID, !message.isSystem, !message.isDeleted,
                  message.kind != .commentDeleted, !message.deliveryState.isPending
            else { return nil }
            let words = text(message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return nil }
            let cut = words.count > messageLimit ? String(words.prefix(messageLimit)) + "…" : words
            return Line(author: message.actor.resolvedDisplayName, text: cut)
        }
    }

    /// Most chunks a long summary is made from: at about ten seconds a chunk on the Mac's
    /// model, more than this is a wait nobody asked for. The newest are kept.
    static let maximumChunks = 8

    /// Every line, oldest first, in transcripts that each fit the model — for summarizing more
    /// than one window holds: each chunk is noted down, then the notes summarized. Past
    /// ``maximumChunks``, the oldest go.
    static func chunks(_ lines: [Line], budget: Int = characterBudget, maximum: Int = maximumChunks) -> [String] {
        var chunks: [[String]] = []
        var current: [String] = []
        var used = 0
        for line in lines {
            let rendered = "\(line.author): \(line.text)"
            if used + rendered.count + 1 > budget, !current.isEmpty {
                chunks.append(current)
                current = []
                used = 0
            }
            current.append(rendered)
            used += rendered.count + 1
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.suffix(maximum).map { $0.joined(separator: "\n") }
    }

    /// The transcript for the model, oldest first, and how many of the lines made it in. When
    /// they don't all fit, the newest are kept — they are what someone catching up needs.
    static func transcript(_ lines: [Line], budget: Int = characterBudget) -> (text: String, included: Int) {
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let rendered = "\(line.author): \(line.text)"
            guard used + rendered.count + 1 <= budget || kept.isEmpty else { break }
            kept.append(rendered)
            used += rendered.count + 1
        }
        return (kept.reversed().joined(separator: "\n"), kept.count)
    }
}
