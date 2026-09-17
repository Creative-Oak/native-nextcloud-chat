import Foundation

/// Someone's out-of-office, as they set it in Nextcloud — what Talk's web app shows at the
/// top of a one-to-one conversation.
struct Absence: Sendable, Hashable {
    var userID: String
    var start: Date
    var end: Date
    var shortMessage: String
    var message: String
    /// Who to ask instead, if they said.
    var replacementUserID: String?
    var replacementDisplayName: String?

    /// The last day they're away, for "until Friday". The end is where the absence stops,
    /// so the day that contains it is only counted when it isn't exactly its start.
    func lastDay(calendar: Calendar = .current) -> Date {
        let startOfEndDay = calendar.startOfDay(for: end)
        return end == startOfEndDay ? end.addingTimeInterval(-1) : end
    }

    /// The first morning they are plausibly going to read it: the day after the last day
    /// away, at `hour`, and not at the weekend.
    ///
    /// This is a guess about a human being, not a fact about a calendar, so it is offered
    /// rather than applied — the composer suggests it and the user says yes. Nil when they
    /// are back already, or would be back before the message could be sent, in which case
    /// there is nothing to suggest.
    func firstMorningBack(calendar: Calendar = .current, hour: Int = 8, now: Date = Date()) -> Date? {
        guard var day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay(calendar: calendar)))
        else { return nil }

        // Saturday is 7 and Sunday is 1 in `Calendar`'s numbering. Two hops at most, so
        // this can't run away even if a calendar disagrees with that.
        for _ in 0..<2 {
            let weekday = calendar.component(.weekday, from: day)
            guard weekday == 7 || weekday == 1 else { break }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        guard let morning = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
              morning > now
        else { return nil }
        return morning
    }
}
