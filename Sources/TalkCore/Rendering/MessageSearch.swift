import Foundation

/// Finding a message you remember, in the conversation you're looking at.
///
/// Local, over what is already loaded and cached — which is what makes it instant. The
/// server-side search (Talk's unified search provider) would reach further back and is the
/// obvious next step; this covers the common case of "it was somewhere this week".
enum MessageSearch {
    struct Match: Sendable, Hashable, Identifiable {
        var id: Int { messageID }
        var messageID: Int
        /// What to show in the results list.
        var preview: String
        var author: String
        var timestamp: Date
    }

    /// Case- and diacritic-insensitive, so "Jose" finds "José" and "BUDGET" finds "budget".
    ///
    /// Searches the rendered text rather than the raw message, so a search for a person's
    /// name finds `@mentions` of them and a search for a filename finds the file share —
    /// neither of which appear literally in `message`.
    static func matches(
        in messages: [Message],
        query: String,
        parser: MessageContentParser,
        limit: Int = 200
    ) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }

        var results: [Match] = []
        // Newest first: the thing you're looking for is usually recent.
        for message in messages.reversed() {
            guard results.count < limit else { break }
            guard message.isVisible, !message.isDeleted else { continue }

            let preview = parser.parse(message).preview
            let haystack = preview + " " + message.actor.resolvedDisplayName
            guard haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }

            results.append(Match(
                messageID: message.messageID,
                preview: preview,
                author: message.actor.resolvedDisplayName,
                timestamp: message.timestamp
            ))
        }
        return results
    }

    /// The range to highlight inside a preview, for the results list.
    static func highlightRange(of query: String, in text: String) -> Range<String.Index>? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }
}
