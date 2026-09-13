import Foundation

/// One entry from the mention autocomplete endpoint.
struct MentionSuggestion: Sendable, Hashable, Identifiable {
    enum Source: String, Sendable, Hashable {
        case users
        case federatedUsers = "federated_users"
        case groups = "group"
        case guests
        case calls
        case other

        init(rawValue: String) {
            switch rawValue {
            case "users": self = .users
            case "federated_users": self = .federatedUsers
            case "group", "groups": self = .groups
            case "guests": self = .guests
            case "calls", "call": self = .calls
            default: self = .other
            }
        }
    }

    /// The participant id.
    var id: String
    /// What to show in the list.
    var label: String
    /// **What to put in the message.** The docs are explicit that this, not `id`, is the
    /// thing that goes after the `@`.
    var mentionID: String
    var source: Source
    var status: UserStatus?
    /// Subline, used by the "Everyone" entry.
    var details: String?

    var isEveryone: Bool { source == .calls }
}

/// Builds and detects `@mentions` in composer text.
///
/// The syntax comes from the Talk documentation: the `mentionId` is written after an `@`,
/// and "ids that contain spaces or slashes need to be wrapped in double-quotes".
enum MentionComposer {
    /// The `@…` the caret is currently inside, if any.
    struct Query: Sendable, Equatable {
        /// UTF-16-ish offsets into the composer string, matching what AppKit's text view uses.
        var start: Int
        var end: Int
        /// The text typed after the `@` — what to search for.
        var text: String
    }

    /// Finds the mention being typed at `caret`.
    ///
    /// A mention starts at an `@` that is either at the very beginning or preceded by
    /// whitespace — so an email address never opens the autocomplete.
    static func activeQuery(in text: String, caret: Int) -> Query? {
        let characters = Array(text)
        guard caret >= 0, caret <= characters.count else { return nil }

        var index = caret - 1
        while index >= 0 {
            let character = characters[index]
            if character == "@" {
                let isStart = index == 0
                let precededByWhitespace = index > 0 && characters[index - 1].isWhitespace
                guard isStart || precededByWhitespace else { return nil }
                let typed = String(characters[(index + 1)..<caret])
                return Query(start: index, end: caret, text: typed)
            }
            // A mention query never spans whitespace or a newline.
            if character.isWhitespace || character.isNewline { return nil }
            index -= 1
        }
        return nil
    }

    /// `@alice`, or `@"first last"` when the id needs quoting.
    static func token(for suggestion: MentionSuggestion) -> String {
        token(forMentionID: suggestion.mentionID)
    }

    static func token(forMentionID mentionID: String) -> String {
        let needsQuotes = mentionID.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\"" })
        guard needsQuotes else { return "@\(mentionID)" }
        // A quote inside the id would end the quoted section early.
        let escaped = mentionID.replacingOccurrences(of: "\"", with: "")
        return "@\"\(escaped)\""
    }

    /// Replaces the in-progress query with the finished mention.
    ///
    /// - Returns: the new composer text and where the caret should end up (after the
    ///   trailing space, so the user can keep typing).
    static func apply(
        _ suggestion: MentionSuggestion,
        to text: String,
        replacing query: Query
    ) -> (text: String, caret: Int) {
        let characters = Array(text)
        let prefix = String(characters[0..<min(query.start, characters.count)])
        let suffix = String(characters[min(query.end, characters.count)...])

        let mention = token(for: suggestion)
        // Don't double up the space if the user already typed one after the query.
        let needsSpace = !(suffix.first?.isWhitespace ?? false)
        let inserted = mention + (needsSpace ? " " : "")

        return (prefix + inserted + suffix, prefix.count + inserted.count)
    }
}
