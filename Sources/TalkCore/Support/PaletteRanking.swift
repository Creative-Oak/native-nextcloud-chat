import Foundation

/// How well something answers what was typed into the command palette, and the order
/// answers go in.
///
/// Matching is what the sidebar's search does — case-, diacritic- and width-insensitive,
/// so "jerome" finds Jérôme — but graded: the whole text starting with the query beats a
/// word in it starting with the query, which beats the query anywhere, which beats the
/// query's letters merely in order ("srvmon" for Server Monitoring — fuzzy, for fast
/// fingers). Ties keep the order the candidates came in, so a list that is already sorted
/// by what matters (unread and recent first; the menu's own order) stays that way within
/// a grade.
enum PaletteRanking {
    enum Grade: Int, Comparable, Sendable {
        case none = 0
        case fuzzy = 1
        case substring = 2
        case wordPrefix = 3
        case prefix = 4

        static func < (lhs: Grade, rhs: Grade) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The best grade any of `texts` earns against `query`. An empty query passes
    /// everything at the lowest grade, so an empty palette still lists.
    static func grade(_ query: String, against texts: [String]) -> Grade {
        let needle = fold(query)
        guard !needle.isEmpty else { return .substring }
        var best = Grade.none
        for text in texts {
            let hay = fold(text)
            let grade: Grade
            if hay.hasPrefix(needle) {
                grade = .prefix
            } else if words(of: hay).contains(where: { $0.hasPrefix(needle) }) {
                grade = .wordPrefix
            } else if hay.contains(needle) {
                grade = .substring
            } else if isSubsequence(needle, of: hay) {
                grade = .fuzzy
            } else {
                grade = .none
            }
            if grade > best { best = grade }
            if best == .prefix { break }
        }
        return best
    }

    /// The `candidates` that match `query`: best grade first, ties in the order they
    /// came, at most `limit` of them.
    static func rank<Candidate>(
        _ candidates: [Candidate],
        query: String,
        limit: Int,
        texts: (Candidate) -> [String]
    ) -> [Candidate] {
        let graded = candidates.enumerated().compactMap { index, candidate -> (order: Int, grade: Grade, candidate: Candidate)? in
            let grade = grade(query, against: texts(candidate))
            return grade == .none ? nil : (index, grade, candidate)
        }
        return graded
            .sorted { lhs, rhs in lhs.grade == rhs.grade ? lhs.order < rhs.order : lhs.grade > rhs.grade }
            .prefix(limit)
            .map(\.candidate)
    }

    private static func fold(_ text: String) -> String {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Fast path: most text has none of these in it.
        guard folded.contains(where: { transliterations[$0] != nil }) else { return folded }
        return String(folded.flatMap { transliterations[$0] ?? String($0) })
    }

    /// The letters `diacriticInsensitive` cannot reach.
    ///
    /// It decomposes a letter into a base and a mark — é is *e* and an acute, å is *a* and a
    /// ring — and strips the mark. But ø, æ and ß are letters in their own right, with no
    /// mark to take off, so folding leaves them exactly as they were and "Rodder" never finds
    /// Rødder. On a server full of Danish names that is most of them.
    private static let transliterations: [Character: String] = [
        "ø": "o", "æ": "ae", "œ": "oe", "ß": "ss",
        "đ": "d", "ð": "d", "þ": "th", "ł": "l", "ı": "i", "ħ": "h", "ŋ": "n"
    ]

    private static func words(of text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// Every character of `needle`, in order, somewhere in `hay`. Spaces in the needle
    /// are not required of the hay: "hvr" and "h v r" both find Heine Volder Rødder.
    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var remaining = needle.filter { !$0.isWhitespace }[...]
        for character in hay {
            if let next = remaining.first, next == character {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return true }
            }
        }
        return remaining.isEmpty
    }
}
