import Foundation

/// A time somebody named in a sentence, and the words that named it.
///
/// "lad os snakke om det i morgen" carries one: the phrase `i morgen`, at characters
/// 21–29, resolving to tomorrow morning. That range is what the composer underlines and
/// what a click on it turns into a reminder.
struct DateExpression: Sendable, Hashable, Identifiable {
    /// Where the words are, as **character** offsets — the same unit the composer's caret
    /// uses. See `StringCaretOffsets` for why that is not UTF-16.
    let range: Range<Int>
    /// The words as they were written, for the label on the pill.
    let phrase: String
    /// When they mean.
    let date: Date
    /// Whether a time of day was actually said. "i morgen" is a day; "i morgen kl. 14" is
    /// a time, and a suggestion built from it shouldn't second-guess the hour.
    let hasExplicitTime: Bool

    var id: Int { range.lowerBound }
}

/// Finds the times named in a piece of writing, in Danish and English, without a model.
///
/// `NSDataDetector` is the obvious tool and the wrong one here: its date detection is
/// built around English, and the phrases this app sees most — `i morgen`, `på fredag`,
/// `om en uge` — go straight past it. So the common ones are a table, which means they
/// work with Apple Intelligence switched off, on an Intel Mac, on a plane. The on-device
/// model is layered *over* this for what a table can't hold ("på fredag efter frokost"),
/// never under it.
///
/// Deliberately conservative: a false positive puts a blue underline under an innocent
/// word, which is worse than missing one.
struct DateExpressionScanner: Sendable {
    var calendar: Calendar
    /// The hour a bare day means — "i morgen" with no time said.
    var defaultHour: Int

    init(calendar: Calendar = .current, defaultHour: Int = 9) {
        self.calendar = calendar
        self.defaultHour = defaultHour
    }

    /// Every time named in `text`, in the order they were written, dropping any that has
    /// already passed. Overlapping readings are resolved in favour of the longer phrase,
    /// so "i morgen kl. 14" is one suggestion rather than two.
    func scan(_ text: String, now: Date = Date()) -> [DateExpression] {
        let tokens = Tokenizer.tokens(in: text)
        guard !tokens.isEmpty else { return [] }

        var found: [DateExpression] = []
        var index = 0
        while index < tokens.count {
            guard let match = match(tokens, from: index, now: now) else {
                index += 1
                continue
            }
            if let expression = expression(for: match, tokens: tokens, now: now) {
                found.append(expression)
            }
            // Past the whole phrase, so "kl. 14" inside "i morgen kl. 14" isn't read again.
            index = match.end
        }
        return found
    }

    // MARK: - Matching

    /// A day, a time, or a day followed by one, over a run of tokens.
    private struct Match {
        var start: Int
        var end: Int
        var day: DaySpec?
        var time: TimeSpec?
    }

    private func match(_ tokens: [Token], from index: Int, now: Date) -> Match? {
        if let day = DaySpec.match(tokens, at: index) {
            var match = Match(start: index, end: day.end, day: day.spec, time: day.impliedTime)
            // A time right after the day joins it: "i morgen kl. 14", "friday at 2pm".
            // A bare number is not one of those — "i morgen 5 personer" says nothing about
            // five o'clock — so it has to be a clock time that reads as one on its own, or
            // a part of the day like "tidlig".
            if let time = TimeSpec.match(tokens, at: day.end), time.standsAlone || !time.spec.isExplicit {
                match.end = time.end
                match.time = time.spec
            }
            return match
        }
        // A time on its own — "kl. 14" — means today, or tomorrow once today's has gone.
        if let time = TimeSpec.match(tokens, at: index), time.standsAlone {
            return Match(start: index, end: time.end, day: nil, time: time.spec)
        }
        return nil
    }

    // MARK: - Resolving

    private func expression(for match: Match, tokens: [Token], now: Date) -> DateExpression? {
        guard let date = resolve(match, now: now), date > now else { return nil }

        let first = tokens[match.start]
        let last = tokens[match.end - 1]
        return DateExpression(
            range: first.start..<last.end,
            phrase: String(first.source[first.sourceRange.lowerBound..<last.sourceRange.upperBound]),
            date: date,
            hasExplicitTime: match.time?.isExplicit ?? false
        )
    }

    private func resolve(_ match: Match, now: Date) -> Date? {
        // "om tre timer" is measured from now, not from a day on the calendar.
        if let day = match.day, case .interval(let seconds) = day {
            return now.addingTimeInterval(seconds)
        }

        let startOfToday = calendar.startOfDay(for: now)
        let day = match.day.flatMap { startOfDay(for: $0, today: startOfToday) }

        switch (day, match.time) {
        case (let day?, let time?):
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)

        case (let day?, nil):
            // A day with no time: nine in the morning, unless that day is today and nine
            // has been and gone — then the next half hour, which is what "i dag" can
            // usefully mean at two in the afternoon.
            guard let morning = calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) else { return nil }
            if morning > now { return morning }
            guard calendar.isDate(day, inSameDayAs: now) else { return morning }
            return nextHalfHour(after: now)

        case (nil, let time?):
            guard let today = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: startOfToday) else { return nil }
            if today > now { return today }
            return calendar.date(byAdding: .day, value: 1, to: today)

        case (nil, nil):
            return nil
        }
    }

    /// The start of the day a `DaySpec` names.
    private func startOfDay(for spec: DaySpec, today: Date) -> Date? {
        switch spec {
        case .offset(let days):
            return calendar.date(byAdding: .day, value: days, to: today)

        case .weekday(let weekday):
            // The next one after today, so "på fredag" said on a Friday is the one coming.
            return calendar.nextDate(
                after: calendar.date(byAdding: .day, value: 1, to: today) ?? today,
                matching: DateComponents(weekday: weekday),
                matchingPolicy: .nextTime,
                direction: .forward
            ).map { calendar.startOfDay(for: $0) }

        case .nextWeek:
            // Monday, as a week that starts on one does everywhere this app is spoken.
            return calendar.nextDate(
                after: today,
                matching: DateComponents(weekday: 2),
                matchingPolicy: .nextTime,
                direction: .forward
            ).map { calendar.startOfDay(for: $0) }

        case .nextMonth:
            guard let next = calendar.date(byAdding: .month, value: 1, to: today) else { return nil }
            var components = calendar.dateComponents([.year, .month], from: next)
            components.day = 1
            return calendar.date(from: components)

        case .days(let count):
            return calendar.date(byAdding: .day, value: count, to: today)

        case .weeks(let count):
            return calendar.date(byAdding: .weekOfYear, value: count, to: today)

        case .interval:
            // Handled before this point, where `now` is still in hand.
            return nil
        }
    }

    /// The next half hour on the clock, seconds thrown away — "in a bit", said precisely.
    private func nextHalfHour(after now: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let floor = calendar.date(from: components) else { return now.addingTimeInterval(30 * 60) }
        let minute = components.minute ?? 0
        return calendar.date(byAdding: .minute, value: minute < 30 ? 30 - minute : 60 - minute, to: floor) ?? floor
    }
}

// MARK: - What a phrase can say

/// The day half of a phrase.
private enum DaySpec: Sendable, Equatable {
    /// Days from today: 0 today, 1 tomorrow, 2 the day after.
    case offset(Int)
    /// A named day of the week, in `Calendar`'s numbering — Sunday is 1.
    case weekday(Int)
    case nextWeek
    case nextMonth
    case days(Int)
    case weeks(Int)
    /// "om en time" — a stretch of time from now rather than a place on the calendar.
    case interval(TimeInterval)

    struct Hit {
        var spec: DaySpec
        var end: Int
        /// "i aften" says a day *and* an hour in two words.
        var impliedTime: TimeSpec?
    }

    /// The day named at `index`, longest reading first.
    static func match(_ tokens: [Token], at index: Int) -> Hit? {
        guard index < tokens.count else { return nil }

        // Three words: "i næste uge", "the day after tomorrow".
        if let hit = phrase(tokens, index, ["i", "næste", "uge"], .nextWeek) { return hit }
        if let hit = phrase(tokens, index, ["i", "naeste", "uge"], .nextWeek) { return hit }
        if let hit = phrase(tokens, index, ["day", "after", "tomorrow"], .offset(2)) { return hit }

        // Two words.
        if let hit = phrase(tokens, index, ["i", "dag"], .offset(0)) { return hit }
        if let hit = phrase(tokens, index, ["i", "morgen"], .offset(1)) { return hit }
        if let hit = phrase(tokens, index, ["i", "overmorgen"], .offset(2)) { return hit }
        if let hit = phrase(tokens, index, ["i", "aften"], .offset(0), time: .daypart(.evening)) { return hit }
        if let hit = phrase(tokens, index, ["i", "nat"], .offset(0), time: .daypart(.night)) { return hit }
        if let hit = phrase(tokens, index, ["næste", "uge"], .nextWeek) { return hit }
        if let hit = phrase(tokens, index, ["naeste", "uge"], .nextWeek) { return hit }
        if let hit = phrase(tokens, index, ["næste", "måned"], .nextMonth) { return hit }
        if let hit = phrase(tokens, index, ["next", "week"], .nextWeek) { return hit }
        if let hit = phrase(tokens, index, ["next", "month"], .nextMonth) { return hit }

        // One word.
        if let hit = phrase(tokens, index, ["idag"], .offset(0)) { return hit }
        if let hit = phrase(tokens, index, ["imorgen"], .offset(1)) { return hit }
        if let hit = phrase(tokens, index, ["today"], .offset(0)) { return hit }
        if let hit = phrase(tokens, index, ["tomorrow"], .offset(1)) { return hit }
        if let hit = phrase(tokens, index, ["tonight"], .offset(0), time: .daypart(.evening)) { return hit }

        if let hit = weekday(tokens, at: index) { return hit }
        if let hit = relative(tokens, at: index) { return hit }
        return nil
    }

    /// "på fredag", "on Friday", "næste fredag", or the bare day on its own.
    private static func weekday(_ tokens: [Token], at index: Int) -> Hit? {
        // The words that can lead a weekday, so "på" is eaten rather than left outside the
        // underline. Danish "i" is not among them: "i fredag" is last Friday.
        let leading = ["på", "paa", "næste", "naeste", "on", "next", "this"]
        var cursor = index
        if cursor + 1 < tokens.count, leading.contains(tokens[cursor].text) {
            cursor += 1
        }
        guard cursor < tokens.count, let weekday = Vocabulary.weekdays[tokens[cursor].text] else { return nil }
        return Hit(spec: .weekday(weekday), end: cursor + 1, impliedTime: nil)
    }

    /// "om en time", "om tre dage", "in two weeks", "in 45 minutes".
    private static func relative(_ tokens: [Token], at index: Int) -> Hit? {
        guard tokens[index].text == "om" || tokens[index].text == "in" else { return nil }
        var cursor = index + 1
        guard cursor < tokens.count else { return nil }

        // "om et par dage" — the pair counts as two.
        var count: Int
        if cursor + 1 < tokens.count, ["et", "a"].contains(tokens[cursor].text), ["par", "couple", "few"].contains(tokens[cursor + 1].text) {
            count = tokens[cursor + 1].text == "few" ? 3 : 2
            cursor += 2
            // "a couple of days"
            if cursor < tokens.count, tokens[cursor].text == "of" { cursor += 1 }
        } else if let number = Vocabulary.number(tokens[cursor].text) {
            count = number
            cursor += 1
        } else {
            return nil
        }

        guard cursor < tokens.count, let unit = Vocabulary.units[tokens[cursor].text] else { return nil }
        let end = cursor + 1
        switch unit {
        case .minute: return Hit(spec: .interval(TimeInterval(count * 60)), end: end, impliedTime: nil)
        case .hour: return Hit(spec: .interval(TimeInterval(count * 3600)), end: end, impliedTime: nil)
        case .day: return Hit(spec: .days(count), end: end, impliedTime: nil)
        case .week: return Hit(spec: .weeks(count), end: end, impliedTime: nil)
        case .month: return Hit(spec: .days(count * 30), end: end, impliedTime: nil)
        }
    }

    private static func phrase(
        _ tokens: [Token],
        _ index: Int,
        _ words: [String],
        _ spec: DaySpec,
        time: TimeSpec? = nil
    ) -> Hit? {
        guard index + words.count <= tokens.count else { return nil }
        for (offset, word) in words.enumerated() where tokens[index + offset].text != word {
            return nil
        }
        return Hit(spec: spec, end: index + words.count, impliedTime: time)
    }
}

/// The time half of a phrase.
private struct TimeSpec: Sendable, Equatable {
    var hour: Int
    var minute: Int
    /// A clock time somebody actually said, rather than what "eftermiddag" comes to.
    var isExplicit: Bool

    enum Daypart: Sendable {
        case morning, forenoon, noon, afternoon, evening, night
    }

    static func daypart(_ part: Daypart) -> TimeSpec {
        switch part {
        case .morning: TimeSpec(hour: 8, minute: 0, isExplicit: false)
        case .forenoon: TimeSpec(hour: 10, minute: 0, isExplicit: false)
        case .noon: TimeSpec(hour: 12, minute: 0, isExplicit: false)
        case .afternoon: TimeSpec(hour: 14, minute: 0, isExplicit: false)
        case .evening: TimeSpec(hour: 19, minute: 0, isExplicit: false)
        case .night: TimeSpec(hour: 22, minute: 0, isExplicit: false)
        }
    }

    struct Hit {
        var spec: TimeSpec
        var end: Int
        /// Whether this reading is strong enough to be a suggestion by itself. "kl. 14" is;
        /// the word "aften" on its own is not — half the sentences in a chat contain one.
        var standsAlone: Bool
    }

    static func match(_ tokens: [Token], at index: Int) -> Hit? {
        guard index < tokens.count else { return nil }
        var cursor = index

        // A lead-in: "kl.", "klokken", "at", "around", "ca."
        var hadLead = false
        if Vocabulary.timeLeads.contains(tokens[cursor].text), cursor + 1 < tokens.count {
            hadLead = true
            cursor += 1
        }

        if let clock = clock(tokens, at: cursor) {
            return Hit(spec: clock.spec, end: clock.end, standsAlone: hadLead || clock.isUnambiguous)
        }

        // "i morgen tidlig", "friday morning", "efter frokost".
        if tokens[cursor].text == "efter" || tokens[cursor].text == "after", cursor + 1 < tokens.count {
            if let part = Vocabulary.dayparts[tokens[cursor + 1].text] {
                // After lunch is not lunch: an hour past whatever the word means.
                let base = TimeSpec.daypart(part)
                return Hit(spec: TimeSpec(hour: min(base.hour + 1, 23), minute: 0, isExplicit: false), end: cursor + 2, standsAlone: false)
            }
        }
        if let part = Vocabulary.dayparts[tokens[cursor].text] {
            return Hit(spec: .daypart(part), end: cursor + 1, standsAlone: false)
        }
        return nil
    }

    private struct Clock {
        var spec: TimeSpec
        var end: Int
        /// "14:30" can only be a time. A bare "14" needs "kl." in front of it to be one.
        var isUnambiguous: Bool
    }

    private static func clock(_ tokens: [Token], at index: Int) -> Clock? {
        guard index < tokens.count else { return nil }
        var end = index + 1
        var digits = tokens[index].text
        var meridiem: Vocabulary.Meridiem?

        // "2pm" is one word to the tokenizer, "2 pm" is two. Both are the same time.
        if digits.count > 2, let suffix = Vocabulary.meridiems[String(digits.suffix(2))], digits.dropLast(2).last?.isNumber == true {
            meridiem = suffix
            digits = String(digits.dropLast(2))
        }

        // 14:30, 14.30 — and 9, 14, which need their lead-in to count.
        let parts = digits.components(separatedBy: CharacterSet(charactersIn: ":."))
        guard let first = parts.first, let hour = Int(first), parts.count <= 2 else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard let value = Int(parts[1]), value < 60, parts[1].count == 2 else { return nil }
            minute = value
        }

        if meridiem == nil, end < tokens.count, let separate = Vocabulary.meridiems[tokens[end].text] {
            meridiem = separate
            end += 1
        }

        if let meridiem {
            guard hour >= 1, hour <= 12 else { return nil }
            let resolved = meridiem == .pm ? (hour == 12 ? 12 : hour + 12) : (hour == 12 ? 0 : hour)
            return Clock(spec: TimeSpec(hour: resolved, minute: minute, isExplicit: true), end: end, isUnambiguous: true)
        }

        guard hour < 24 else { return nil }
        // A number with minutes on it is a clock; a bare number is only one when something
        // said so, which is what the lead-in is for.
        return Clock(
            spec: TimeSpec(hour: hour, minute: minute, isExplicit: true),
            end: end,
            isUnambiguous: parts.count == 2
        )
    }
}

// MARK: - Words

private enum Vocabulary {
    /// `Calendar` numbers the week from Sunday.
    static let weekdays: [String: Int] = [
        "søndag": 1, "soendag": 1, "sunday": 1,
        "mandag": 2, "monday": 2,
        "tirsdag": 3, "tuesday": 3,
        "onsdag": 4, "wednesday": 4,
        "torsdag": 5, "thursday": 5,
        "fredag": 6, "friday": 6,
        "lørdag": 7, "loerdag": 7, "saturday": 7
    ]

    static let dayparts: [String: TimeSpec.Daypart] = [
        "morgen": .morning, "tidlig": .morning, "morgenen": .morning, "morning": .morning,
        "formiddag": .forenoon, "formiddagen": .forenoon,
        "middag": .noon, "frokost": .noon, "frokosten": .noon, "frokosttid": .noon,
        "noon": .noon, "lunch": .noon, "lunchtime": .noon,
        "eftermiddag": .afternoon, "eftermiddagen": .afternoon, "afternoon": .afternoon,
        "aften": .evening, "aftenen": .evening, "evening": .evening, "tonight": .evening,
        "nat": .night, "natten": .night, "night": .night
    ]

    static let timeLeads: Set<String> = ["kl", "klokken", "at", "ca", "omkring", "around", "cirka"]

    enum Meridiem { case am, pm }
    static let meridiems: [String: Meridiem] = ["am": .am, "pm": .pm, "a.m": .am, "p.m": .pm]

    enum Unit { case minute, hour, day, week, month }
    static let units: [String: Unit] = [
        "minut": .minute, "minutter": .minute, "min": .minute, "minute": .minute, "minutes": .minute,
        "time": .hour, "timer": .hour, "hour": .hour, "hours": .hour,
        "dag": .day, "dage": .day, "day": .day, "days": .day,
        "uge": .week, "uger": .week, "week": .week, "weeks": .week,
        "måned": .month, "måneder": .month, "month": .month, "months": .month
    ]

    private static let numberWords: [String: Int] = [
        "en": 1, "et": 1, "one": 1, "a": 1, "an": 1,
        "to": 2, "two": 2,
        "tre": 3, "three": 3,
        "fire": 4, "four": 4,
        "fem": 5, "five": 5,
        "seks": 6, "six": 6,
        "syv": 7, "seven": 7,
        "otte": 8, "eight": 8,
        "ni": 9, "nine": 9,
        "ti": 10, "ten": 10,
        "elleve": 11, "eleven": 11,
        "tolv": 12, "twelve": 12
    ]

    static func number(_ token: String) -> Int? {
        if let digits = Int(token), digits > 0, digits <= 500 { return digits }
        return numberWords[token]
    }
}

// MARK: - Tokens

/// One word, with where it sits in the sentence.
private struct Token {
    /// Lowercased, with any trailing full stop taken off — so "kl." matches "kl".
    let text: String
    let start: Int
    let end: Int
    let source: String
    let sourceRange: Range<String.Index>
}

private enum Tokenizer {
    /// Words and clock times. A full stop or colon between digits stays inside the token,
    /// so "14.30" survives, while the one that ends a sentence does not.
    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        var offset = 0

        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter || character.isNumber else {
                index = text.index(after: index)
                offset += 1
                continue
            }

            let start = index
            let startOffset = offset
            var end = index
            var endOffset = offset

            while end < text.endIndex {
                let current = text[end]
                if current.isLetter || current.isNumber {
                    end = text.index(after: end)
                    endOffset += 1
                    continue
                }
                // A separator only belongs to the token when a digit or letter carries on
                // after it: "14:30" and "p.m" hold together, "fredag." does not.
                if current == ":" || current == "." {
                    let after = text.index(after: end)
                    if after < text.endIndex, text[after].isLetter || text[after].isNumber {
                        end = text.index(after: after)
                        endOffset += 2
                        continue
                    }
                }
                break
            }

            tokens.append(Token(
                text: text[start..<end].lowercased(),
                start: startOffset,
                end: endOffset,
                source: text,
                sourceRange: start..<end
            ))
            index = end
            offset = endOffset
        }
        return tokens
    }
}
