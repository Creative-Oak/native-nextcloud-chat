import Foundation

/// Something a message is asking to become.
///
/// The one-tap row under a bubble — Messages' "Add to Reminders", "Add to Notes" — is
/// built from these. What they *do* is the app's business; what is worth offering is
/// decided here, where it can be tested without a window.
struct MessageSuggestion: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        /// A time was named, and it hasn't passed.
        case remind(Date)
        /// The message is worth keeping: a list, or something to be looked up later.
        case note
    }

    let kind: Kind
    /// The words that earned the suggestion — the phrase for a reminder, so the chip can
    /// say what it read.
    let phrase: String?

    var id: String {
        switch kind {
        case .remind(let date): "remind-\(Int(date.timeIntervalSince1970))"
        case .note: "note"
        }
    }
}

/// What a message suggests, without a model.
///
/// Conservative on purpose. A chip under every message is noise, and noise is how a
/// feature like this gets switched off — so a suggestion needs a reason that survives
/// being written down as a rule. The on-device model refines what this finds; it is not
/// allowed to invent suggestions this wouldn't make, which is what keeps the row quiet.
enum SuggestionScanner {
    /// At most one of each kind, in the order they'd be shown.
    static func suggestions(
        for text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MessageSuggestion] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return [] }

        var suggestions: [MessageSuggestion] = []

        let scanner = DateExpressionScanner(calendar: calendar)
        if let expression = scanner.scan(trimmed, now: now).first {
            suggestions.append(MessageSuggestion(kind: .remind(expression.date), phrase: expression.phrase))
        }

        if isWorthKeeping(trimmed) {
            suggestions.append(MessageSuggestion(kind: .note, phrase: nil))
        }
        return suggestions
    }

    /// Whether a message reads like something you'd want to keep rather than to answer.
    ///
    /// Two shapes qualify, and nothing else: a written-out list, and a sentence that hands
    /// you a list inline — "vi skal bruge: chips, tomater, ananas". Both are the case
    /// Apple's own screenshot shows, and both are rare enough in ordinary chat that the
    /// chip stays a surprise rather than a fixture.
    static func isWorthKeeping(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let bulleted = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return false }
            if first == "-" || first == "*" || first == "•" { return true }
            // "1." or "1)" — a numbered list.
            let prefix = trimmed.prefix(3)
            return prefix.first?.isNumber == true && (prefix.contains(".") || prefix.contains(")"))
        }
        if bulleted.count >= 2 { return true }

        // An inline list: something introduced with a colon, then commas.
        guard let colon = text.firstIndex(of: ":") else { return false }
        let tail = text[text.index(after: colon)...]
        let items = tail.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return items.count >= 3
    }
}
