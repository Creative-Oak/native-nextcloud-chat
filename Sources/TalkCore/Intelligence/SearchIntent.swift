import Foundation

/// What somebody meant by what they typed into the search field.
///
/// Talk's search is a substring match over message text, so a whole question — "hvad sagde
/// Heine om fakturaen i sidste uge" — matches nothing at all, because nobody ever wrote
/// that sentence. This is the shape of a search that will actually find something.
struct SearchIntent: Sendable, Equatable {
    /// What is sent to the server.
    var terms: String
    /// Whose messages, if they said. Matched against the hit's title, which is where Talk
    /// puts "{user} in {conversation}".
    var author: String?
    /// Only messages at or after this.
    var after: Date?
    /// Only messages before this.
    var before: Date?

    /// Whether this is anything other than what was typed. When it isn't, the search field
    /// says nothing about it — there is no point announcing that a search was searched.
    func changesAnything(from typed: String) -> Bool {
        author != nil || after != nil || before != nil
            || terms.caseInsensitiveCompare(typed.trimmingCharacters(in: .whitespaces)) != .orderedSame
    }

    /// How the change reads under the field, so nobody is left wondering why they got
    /// different results from the ones they asked for.
    func explanation(dateStyle: Date.FormatStyle = .dateTime.day().month(.abbreviated)) -> String {
        var parts = ["Searching for “\(terms)”"]
        if let author { parts.append("from \(author)") }
        if let after { parts.append("after \(after.formatted(dateStyle))") }
        if let before { parts.append("before \(before.formatted(dateStyle))") }
        return parts.joined(separator: ", ")
    }

    /// Whether a hit survives the parts of the intent the server can't apply itself.
    func admits(title: String, timestamp: Date) -> Bool {
        if let author, !title.localizedCaseInsensitiveContains(author) { return false }
        if let after, timestamp < after { return false }
        if let before, timestamp >= before { return false }
        return true
    }
}

/// Turning a typed question into something a substring search can answer.
///
/// The model does this better, and does the parts this can't do at all — who, and when. But
/// this runs first, instantly, and on every Mac: dropping the words nobody puts in a message
/// is most of the difference between a search that finds the invoice and one that finds
/// nothing.
enum NaturalLanguageQuery {
    /// Whether what was typed reads like a question rather than a search term.
    ///
    /// Two words are a search. "hvad sagde heine om fakturaen" is somebody talking to the
    /// app, and it is the only case worth touching — nobody's two-word search needs help.
    static func looksConversational(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else { return false }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return questionOpeners.contains(where: { folded.hasPrefix($0) })
            || words.contains { stopWords.contains(String($0).lowercased()) }
    }

    /// What was typed with the words nobody writes in a message taken out.
    ///
    /// Falls back to the whole text if stripping leaves nothing — an empty search finds
    /// everything, which is the one answer worse than finding nothing.
    static func keywords(from text: String) -> String {
        let kept = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "?" })
            .map(String.init)
            .filter { word in
                let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .trimmingCharacters(in: CharacterSet.punctuationCharacters)
                return !folded.isEmpty && !stopWords.contains(folded)
            }

        let terms = kept.joined(separator: " ")
        return terms.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : terms
    }

    private static let questionOpeners: Set<String> = [
        "hvad", "hvem", "hvornar", "hvilken", "hvilket", "hvor", "hvorfor",
        "what", "who", "when", "which", "where", "why", "find", "show", "vis", "find "
    ]

    /// Words that carry a question rather than a subject. Danish first.
    private static let stopWords: Set<String> = [
        // Danish
        "hvad", "hvem", "hvornar", "hvilken", "hvilket", "hvor", "hvorfor", "sagde", "skrev",
        "skrevet", "sige", "siger", "sagt", "naevnte", "naevnt", "snakkede", "talte",
        "om", "der", "den", "det", "de", "en", "et", "og", "eller", "men", "til", "fra",
        "med", "pa", "i", "af", "for", "er", "var", "har", "havde", "vi", "jeg", "du",
        "han", "hun", "mig", "dig", "sig", "som", "at", "lige", "vist", "mon", "nogen",
        "noget", "sidste", "forrige", "seneste",
        // English
        "what", "who", "when", "which", "where", "why", "said", "says", "say", "wrote",
        "write", "written", "tell", "told", "mention", "mentioned", "about",
        "the", "a", "an", "and", "or", "but", "to", "from", "with", "on", "in", "of",
        "for", "is", "was", "were", "has", "had", "have", "we", "i", "you", "he", "she",
        "me", "that", "did", "does", "do", "anything", "something", "last", "latest"
    ]
}
