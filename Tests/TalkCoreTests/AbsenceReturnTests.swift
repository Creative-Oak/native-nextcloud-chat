import Foundation
import Testing
@testable import TalkCore

/// When someone away is next going to read what you send them — the time the composer
/// offers when you write to a colleague who is out of office.
@Suite("Absence return time")
struct AbsenceReturnTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    /// Wednesday 17 September 2025, 10:00 local.
    private var now: Date {
        date(day: 17, hour: 10)
    }

    private func date(day: Int, month: Int = 9, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour, minute: minute))!
    }

    private func absence(from first: Int, toEndOf last: Int) -> Absence {
        // Nextcloud ends an absence at midnight *after* the last day away.
        Absence(
            userID: "heine",
            start: date(day: first),
            end: date(day: last + 1),
            shortMessage: "Ferie",
            message: "",
            replacementUserID: nil,
            replacementDisplayName: nil
        )
    }

    @Test("Back the morning after the last day away")
    func morningAfter() throws {
        // Away Wednesday and Thursday; back Friday.
        let back = try #require(absence(from: 17, toEndOf: 18).firstMorningBack(calendar: calendar, now: now))
        #expect(calendar.component(.day, from: back) == 19)
        #expect(calendar.component(.hour, from: back) == 8)
    }

    @Test("A Friday finish means Monday, not Saturday")
    func skipsTheWeekend() throws {
        // Away until Friday the 19th; the next working morning is Monday the 22nd.
        let back = try #require(absence(from: 17, toEndOf: 19).firstMorningBack(calendar: calendar, now: now))
        #expect(calendar.component(.day, from: back) == 22)
        #expect(calendar.component(.weekday, from: back) == 2)
    }

    @Test("A Saturday finish also means Monday")
    func saturdayFinish() throws {
        let back = try #require(absence(from: 17, toEndOf: 20).firstMorningBack(calendar: calendar, now: now))
        #expect(calendar.component(.day, from: back) == 22)
    }

    @Test("An absence ending mid-day counts that day as away")
    func endsMidDay() throws {
        var absence = absence(from: 17, toEndOf: 18)
        absence.end = date(day: 18, hour: 15)
        let back = try #require(absence.firstMorningBack(calendar: calendar, now: now))
        #expect(calendar.component(.day, from: back) == 19)
    }

    @Test("Nothing to suggest when they are back before you could send it")
    func alreadyBack() {
        // Away until yesterday: the morning after has already been.
        let absence = absence(from: 14, toEndOf: 15)
        #expect(absence.firstMorningBack(calendar: calendar, now: now) == nil)
    }
}
