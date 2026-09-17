import Foundation
import FoundationModels
import Observation

/// Apple Intelligence, as much of it as this app asks for.
///
/// One type, one import, one place where a prompt is written — everything else in kvidr
/// talks to *this*, so the model can be missing, switched off, or replaced without any of
/// it reaching a view. Three rules hold everywhere below:
///
/// 1. **The model never works alone.** `DateExpressionScanner` and `SuggestionScanner` find
///    what they find with no model at all; this layer is asked only for what a table can't
///    hold. A Mac without Apple Intelligence loses the long tail, not the feature.
/// 2. **The model never invents a range.** It is asked for the *words*, which are then
///    found in the original text here. An offset from a model is a guess; `range(of:)` is
///    not, and a blue underline in the wrong place is the one bug users would never forgive.
/// 3. **Nothing leaves the Mac.** The on-device model is the only one asked, never Private
///    Cloud Compute — a work chat is exactly the content you don't send anywhere.
@MainActor
@Observable
final class OnDeviceIntelligence {
    /// Why the intelligent parts are quiet, in words Settings can show.
    enum Readiness: Equatable {
        case ready
        /// Apple Intelligence is off, still downloading, or this Mac can't run it.
        case unavailable(String)

        var isReady: Bool { self == .ready }
    }

    private(set) var readiness: Readiness = .unavailable("Not checked yet.")
    var isReady: Bool { readiness.isReady }

    /// Made on first use and kept: a session carries its instructions, and rebuilding one
    /// per keystroke would pay for them every time.
    @ObservationIgnored private var dateSession: LanguageModelSession?
    @ObservationIgnored private var replySession: LanguageModelSession?

    init() {
        refreshReadiness()
    }

    /// Asked again when Settings opens and when a conversation is opened, since the user
    /// may have switched Apple Intelligence on in the meantime, or the model may have
    /// finished downloading.
    func refreshReadiness() {
        if case .available = SystemLanguageModel.default.availability {
            readiness = .ready
        } else if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            readiness = .unavailable(Self.explain(reason))
        } else {
            readiness = .unavailable("Apple Intelligence isn’t available right now.")
        }
        if !readiness.isReady {
            dateSession = nil
            replySession = nil
        }
    }

    // MARK: - Times a table doesn't know

    /// Times named in `text` that `DateExpressionScanner` did not already find.
    ///
    /// Returns nothing at all — not an empty list of excuses — when the model is away, so a
    /// caller can treat "no model" and "nothing to add" the same way.
    func refinedDates(in text: String, alreadyFound: [DateExpression], now: Date = Date()) async -> [DateExpression] {
        guard isReady, text.count >= 8, text.count <= 1000 else { return [] }

        let session = dateSession ?? LanguageModelSession { Self.dateInstructions }
        dateSession = session
        guard !session.isResponding else { return [] }

        let prompt = """
        Today is \(Self.stamp.string(from: now)) (\(Self.weekday.string(from: now))).
        Message: "\(text)"
        """

        let found: RefinedTimes
        do {
            found = try await session.respond(to: prompt, generating: RefinedTimes.self).content
        } catch {
            // A guardrail trip, a context overflow, the model going away mid-sentence: all
            // of them mean the same thing here, which is that the table's answer stands.
            Log.ui.debug("On-device date refinement declined: \(error.localizedDescription)")
            return []
        }

        let taken = alreadyFound.map(\.range)
        var refined: [DateExpression] = []
        for time in found.times.prefix(3) {
            guard let expression = expression(for: time, in: text, now: now) else { continue }
            guard !taken.contains(where: { $0.overlaps(expression.range) }) else { continue }
            guard !refined.contains(where: { $0.range.overlaps(expression.range) }) else { continue }
            refined.append(expression)
        }
        return refined
    }

    /// Turns one answer into an expression, or refuses it.
    ///
    /// Rule 2 in the type's own words: the phrase has to be *in* the message, and the date
    /// has to be a real one between now and a year out. Anything else is dropped without
    /// ceremony — there is always a next keystroke.
    private func expression(for time: RefinedTime, in text: String, now: Date) -> DateExpression? {
        let phrase = time.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 2, phrase.count <= 40 else { return nil }
        guard let range = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        guard let date = Self.stampWithTime.date(from: time.when.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard date > now, date < now.addingTimeInterval(365 * 24 * 60 * 60) else { return nil }

        return DateExpression(
            range: text.distance(from: text.startIndex, to: range.lowerBound)
                ..< text.distance(from: text.startIndex, to: range.upperBound),
            phrase: String(text[range]),
            date: date,
            hasExplicitTime: true
        )
    }

    // MARK: - Replies

    /// Two or three replies to the last thing said, in the language it was said in.
    ///
    /// The user's own recent messages go in as the example of how they write — which is the
    /// difference between a suggestion they'd send and one that sounds like a brochure.
    func replies(to transcript: String, inTheStyleOf ownMessages: [String]) async -> [String] {
        guard isReady, !transcript.isEmpty else { return [] }

        let session = replySession ?? LanguageModelSession { Self.replyInstructions }
        replySession = session
        guard !session.isResponding else { return [] }

        let style = ownMessages.isEmpty
            ? "No examples available; keep it plain and friendly."
            : ownMessages.prefix(6).map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        How this person writes, for tone and language only — never copy their content:
        \(style)

        The conversation so far, oldest first:
        \(transcript)

        Suggest replies to the last message.
        """

        do {
            let replies = try await session.respond(to: prompt, generating: SuggestedReplies.self).content
            return replies.replies
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 80 }
                .reduce(into: [String]()) { unique, reply in
                    if !unique.contains(where: { $0.caseInsensitiveCompare(reply) == .orderedSame }) { unique.append(reply) }
                }
                .prefix(3)
                .map { $0 }
        } catch {
            Log.ui.debug("On-device replies declined: \(error.localizedDescription)")
            return []
        }
    }

    /// Thrown away when the conversation changes, so nothing one room said is in the
    /// context of the next. A transcript is cheap to rebuild and a leak between rooms is not.
    func forgetContext() {
        dateSession = nil
        replySession = nil
    }

    // MARK: - Instructions and formats

    /// Why Apple Intelligence isn't answering, in words that belong in Settings rather
    /// than in a crash report.
    private static func explain(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is switched off in System Settings."
        case .deviceNotEligible:
            "This Mac doesn’t support Apple Intelligence."
        case .modelNotReady:
            "Apple Intelligence is still downloading its model. This finishes on its own."
        default:
            "Apple Intelligence isn’t available right now."
        }
    }

    private static let dateInstructions = """
    You read one chat message and report every time or date it names.

    Rules:
    - Copy the phrase exactly as it appears in the message. Never paraphrase or translate it.
    - Only report a phrase that genuinely fixes a point in time. "om det", "about it", \
    "på den måde" and similar name no time at all.
    - Resolve relative phrases against the date you are given.
    - When no time of day is said, use 09:00.
    - Messages are often in Danish. "i morgen" is tomorrow, "i overmorgen" is the day after, \
    "på fredag" is the coming Friday, "om en uge" is a week from today.
    - If the message names no time, report none. An empty answer is a good answer.
    """

    private static let replyInstructions = """
    You suggest short replies that a person could send as-is in a work chat.

    Rules:
    - Reply in the same language the conversation is in. Danish in, Danish out.
    - Two to three suggestions, each under eight words, all different from each other.
    - Match how the person writes: their length, their punctuation, their formality.
    - Plain sentences. No emoji unless the conversation uses them, no greetings, no sign-offs.
    - Never invent a commitment, a time, a price or a fact. "Det kigger jeg på" is a reply; \
    "Jeg sender den kl. 14" is a promise you are not allowed to make for them.
    - Never suggest anything about a person's health, beliefs, or anything private.
    """

    private static let stamp: DateFormatter = formatter("yyyy-MM-dd")
    private static let weekday: DateFormatter = formatter("EEEE")
    private static let stampWithTime: DateFormatter = formatter("yyyy-MM-dd HH:mm")

    /// Fixed format, fixed locale: this is a wire format between two pieces of software
    /// that happen to be in the same process, not something anybody reads.
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

/// What the model answers with when asked about times.
@Generable
private struct RefinedTimes {
    @Guide(description: "Every time or date the message names. Empty when it names none. At most three.")
    var times: [RefinedTime]
}

@Generable
private struct RefinedTime {
    @Guide(description: "The words from the message that name this time, copied exactly, in the message's own language.")
    var phrase: String

    @Guide(description: "When those words mean, as yyyy-MM-dd HH:mm, in the reader's own time zone.")
    var when: String
}

/// What the model answers with when asked for replies.
@Generable
private struct SuggestedReplies {
    @Guide(description: "Two or three short replies, in the conversation's language, each under eight words.")
    var replies: [String]
}
