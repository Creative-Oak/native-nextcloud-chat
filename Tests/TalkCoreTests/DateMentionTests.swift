import Foundation
import Testing
@testable import TalkCore

struct DateMentionTests {
    @Test func aDayAndATimeAreFound() throws {
        let mention = try #require(DateMention.first(in: "Shall we meet on 24 September 2026 at 10:30 in the office?"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: mention.date)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 24)
        #expect(parts.hour == 10 && parts.minute == 30)
        #expect(mention.hasTime)
    }

    @Test func aDayAloneHasNoTime() throws {
        let mention = try #require(DateMention.first(in: "The report is due 30 October 2026."))
        #expect(!mention.hasTime)
    }

    @Test func noDateNoMention() {
        #expect(DateMention.first(in: "Thanks, sounds good!") == nil)
    }

    @Test func timesAreToldFromDays() {
        #expect(DateMention.mentionsTime("tomorrow at 3pm"))
        #expect(DateMention.mentionsTime("i morgen kl. 14"))
        #expect(DateMention.mentionsTime("Friday 09.15"))
        #expect(!DateMention.mentionsTime("next Friday"))
    }
}
