import Foundation
import Testing
@testable import TalkCore

/// The phrases that earn a blue underline in the composer, and the times they come to.
///
/// Every case is fixed to a known "now" — Wednesday 17 September 2025, 10:00, in a
/// calendar whose week starts on Monday — so nothing here depends on the day the tests run.
@Suite("Date expressions")
struct DateExpressionScannerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    /// Wednesday 17 September 2025, 10:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2025, month: 9, day: 17, hour: 10, minute: 0))!
    }

    private func scan(_ text: String) -> [DateExpression] {
        DateExpressionScanner(calendar: calendar).scan(text, now: now)
    }

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func expect(_ text: String, day: Int, month: Int = 9, hour: Int, minute: Int = 0, phrase: String) {
        let found = scan(text)
        guard let first = found.first else {
            Issue.record("nothing found in “\(text)”")
            return
        }
        let components = parts(first.date)
        #expect(components.month == month, "month of “\(text)”")
        #expect(components.day == day, "day of “\(text)”")
        #expect(components.hour == hour, "hour of “\(text)”")
        #expect(components.minute == minute, "minute of “\(text)”")
        #expect(first.phrase == phrase)
    }

    // MARK: - Danish, which is the whole reason this exists

    @Test("The sentence from the brief")
    func theExample() throws {
        let text = "lad os snakke om det i morgen"
        let found = scan(text)
        #expect(found.count == 1)

        let expression = try #require(found.first)
        #expect(expression.phrase == "i morgen")
        // The underline covers exactly those words, and nothing either side of them.
        let start = text.index(text.startIndex, offsetBy: expression.range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: expression.range.upperBound)
        #expect(String(text[start..<end]) == "i morgen")
        #expect(parts(expression.date).day == 18)
        #expect(parts(expression.date).hour == 9)
        #expect(expression.hasExplicitTime == false)
    }

    @Test("Days")
    func danishDays() {
        expect("vi ses i morgen", day: 18, hour: 9, phrase: "i morgen")
        expect("i overmorgen er der møde", day: 19, hour: 9, phrase: "i overmorgen")
        expect("skal vi ses i aften?", day: 17, hour: 19, phrase: "i aften")
        expect("kan du på fredag", day: 19, hour: 9, phrase: "på fredag")
        expect("det tager vi mandag", day: 22, hour: 9, phrase: "mandag")
        expect("vi gør det næste uge", day: 22, hour: 9, phrase: "næste uge")
    }

    @Test("A day and a time, read as one phrase")
    func danishDayAndTime() {
        expect("mødet er i morgen kl. 14", day: 18, hour: 14, phrase: "i morgen kl. 14")
        expect("i morgen kl 14.30 passer", day: 18, hour: 14, minute: 30, phrase: "i morgen kl 14.30")
        expect("ring i morgen tidlig", day: 18, hour: 8, phrase: "i morgen tidlig")
        expect("på fredag efter frokost", day: 19, hour: 13, phrase: "på fredag efter frokost")
    }

    @Test("Stretches of time are measured from now")
    func danishIntervals() {
        expect("jeg ringer om en time", day: 17, hour: 11, phrase: "om en time")
        expect("om 30 minutter", day: 17, hour: 10, minute: 30, phrase: "om 30 minutter")
        expect("om et par dage", day: 19, hour: 9, phrase: "om et par dage")
        expect("om to uger", day: 1, month: 10, hour: 9, phrase: "om to uger")
    }

    @Test("A bare time means today, or tomorrow once it has gone")
    func bareTimes() {
        expect("kl. 14 er fint", day: 17, hour: 14, phrase: "kl. 14")
        // 09:00 has been and gone at ten, so it means tomorrow's.
        expect("kl. 9 er fint", day: 18, hour: 9, phrase: "kl. 9")
    }

    // MARK: - English

    @Test("English reads the same way")
    func english() {
        expect("let's talk tomorrow", day: 18, hour: 9, phrase: "tomorrow")
        expect("see you tomorrow at 2pm", day: 18, hour: 14, phrase: "tomorrow at 2pm")
        expect("shall we say friday morning", day: 19, hour: 8, phrase: "friday morning")
        expect("in two hours", day: 17, hour: 12, phrase: "in two hours")
        expect("next week then", day: 22, hour: 9, phrase: "next week")
        expect("the day after tomorrow", day: 19, hour: 9, phrase: "day after tomorrow")
    }

    // MARK: - Restraint

    @Test("Nothing is found where nothing was said")
    func quiet() {
        #expect(scan("lad os snakke om det").isEmpty)
        #expect(scan("hvad synes du om den nye version?").isEmpty)
        #expect(scan("in a meeting, call you back").isEmpty)
        #expect(scan("der er 14 tilmeldte").isEmpty)
        #expect(scan("").isEmpty)
    }

    @Test("A number after a day is not a time")
    func noStrayNumbers() {
        let found = scan("i morgen 5 personer kommer")
        #expect(found.first?.phrase == "i morgen")
        #expect(parts(found.first!.date).hour == 9)
    }

    @Test("A time that has passed is not offered")
    func pastTimesAreDropped() {
        // Today at 08:00 is behind us at ten, and "i dag" alone rolls forward instead.
        let found = scan("vi gør det i dag")
        #expect(found.count == 1)
        #expect(parts(found[0].date).day == 17)
        #expect(parts(found[0].date).hour == 10)
        #expect(parts(found[0].date).minute == 30)
    }

    @Test("Two phrases in one sentence are both found, in order")
    func several() {
        let found = scan("enten i morgen eller på fredag")
        #expect(found.map(\.phrase) == ["i morgen", "på fredag"])
        #expect(parts(found[0].date).day == 18)
        #expect(parts(found[1].date).day == 19)
    }

    @Test("Ranges count characters, not UTF-16 units")
    func emojiSafeRanges() throws {
        let text = "👍 i morgen"
        let found = scan(text)
        let expression = try #require(found.first)
        let start = text.index(text.startIndex, offsetBy: expression.range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: expression.range.upperBound)
        #expect(String(text[start..<end]) == "i morgen")
    }
}
