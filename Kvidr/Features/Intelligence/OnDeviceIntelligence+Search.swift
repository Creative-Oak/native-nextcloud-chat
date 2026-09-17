import Foundation
import FoundationModels

/// Reading a typed question as a search.
extension OnDeviceIntelligence {
    /// What the question was actually asking for — or nothing, leaving the table's
    /// keyword strip to stand.
    ///
    /// The model supplies the two things a keyword strip cannot: who, and when.
    func readSearchIntent(from question: String, now: Date = Date()) async -> SearchIntent? {
        guard isReady, question.count >= 8, question.count <= 300 else { return nil }

        guard let read = await answer(
            SearchReading.self,
            purpose: .search,
            instructions: Self.searchInstructions,
            prompt: """
            Today is \(Self.searchStamp.string(from: now)).
            The person typed: "\(question)"
            """
        ) else { return nil }

        let terms = read.terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, terms.count <= 120 else { return nil }

        let author = read.author.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name the question didn't contain is the model filling in a blank. It has to be
        // in what was typed, or it doesn't narrow anything.
        let vettedAuthor = !author.isEmpty && author.count <= 60
            && question.localizedCaseInsensitiveContains(author) ? author : nil

        return SearchIntent(
            terms: terms,
            author: vettedAuthor,
            after: date(from: read.after, now: now),
            before: date(from: read.before, now: now)
        )
    }

    /// A date the model wrote, if it is one, and if it is anywhere near sane. Ten years
    /// either side of today: a chat history is not a geological record.
    private func date(from text: String, now: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = Self.searchStamp.date(from: trimmed) else { return nil }
        let decade: TimeInterval = 10 * 365 * 24 * 60 * 60
        guard date > now.addingTimeInterval(-decade), date < now.addingTimeInterval(decade) else { return nil }
        return date
    }

    private static let searchInstructions = """
    You turn a question typed into a chat app's search box into the search that answers it.

    Rules:
    - terms: the words that would actually appear in the message being looked for. Drop \
    question words, verbs of saying, and anything about who or when — those have their own \
    fields. Keep names of things, projects, files and topics.
    - author: the person whose messages are wanted, exactly as the question spells their \
    name. Empty when the question doesn't name one.
    - after and before: yyyy-MM-dd, bounding when the message was sent. "last week" is the \
    seven days before today. Empty when the question says nothing about time.
    - Never widen a search. If in doubt, leave a field empty: an empty field searches \
    everything, and a wrong one hides the answer.
    - Questions are often in Danish. "hvad sagde Heine om fakturaen i sidste uge" is terms \
    "faktura", author "Heine", after last Monday.
    """

    private static let searchStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// What the model answers with when asked to read a search.
@Generable
private struct SearchReading {
    @Guide(description: "The words that would appear in the message itself. Never empty.")
    var terms: String

    @Guide(description: "The person whose messages are wanted, spelled as the question spells it. Empty when none is named.")
    var author: String

    @Guide(description: "Earliest date to include, as yyyy-MM-dd. Empty when the question says nothing about time.")
    var after: String

    @Guide(description: "Latest date to include, as yyyy-MM-dd. Empty when the question says nothing about time.")
    var before: String
}
