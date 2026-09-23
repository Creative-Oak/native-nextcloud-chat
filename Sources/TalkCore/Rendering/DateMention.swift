import Foundation

/// A day or a time a message mentions — "Thursday at 10", "tomorrow", "24 Sept" — found by the
/// system's own date detector, the one Mail and Messages underline with. Words like
/// "tomorrow" are taken from today, as the detector reads them.
struct DateMention: Sendable, Equatable {
    let date: Date
    /// How long, when the text says: "10–11", "for two hours".
    let duration: TimeInterval?
    /// Whether a time of day was said, or only a day.
    let hasTime: Bool
    /// The words it was found in.
    let text: String

    /// Made once: a detector is costly to make, and safe to share.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The first mention in `text`.
    static func first(in text: String) -> DateMention? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var found: DateMention?
        detector.enumerateMatches(in: text, options: [], range: range) { result, _, stop in
            guard let result, let date = result.date, let span = Range(result.range, in: text) else { return }
            let words = String(text[span])
            found = DateMention(
                date: date,
                duration: result.duration > 0 ? result.duration : nil,
                hasTime: Self.mentionsTime(words),
                text: words
            )
            stop.pointee = true
        }
        return found
    }

    /// "10:30", "3pm", "at 10", "kl. 14" — a time of day, not only a day.
    static func mentionsTime(_ words: String) -> Bool {
        let lowered = words.lowercased()
        let patterns = [
            #"\d{1,2}[:.]\d{2}"#,
            #"\d{1,2}\s*(am|pm|a\.m\.|p\.m\.)"#,
            #"\b(at|kl\.?|klokken)\s*\d{1,2}"#,
            #"\b(noon|midnight|middag)\b"#
        ]
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }
}
