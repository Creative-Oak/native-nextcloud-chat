import Foundation
import Testing
@testable import TalkCore

/// What earns a one-tap chip under a message, and — mostly — what doesn't.
@Suite("Message suggestions")
struct MessageSuggestionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2025, month: 9, day: 17, hour: 10, minute: 0))!
    }

    private func suggestions(_ text: String) -> [MessageSuggestion] {
        SuggestionScanner.suggestions(for: text, now: now, calendar: calendar)
    }

    @Test("A time named in a message offers a reminder")
    func reminder() throws {
        let found = suggestions("lad os snakke om det i morgen")
        #expect(found.count == 1)
        let suggestion = try #require(found.first)
        #expect(suggestion.phrase == "i morgen")
        guard case .remind(let date) = suggestion.kind else {
            Issue.record("expected a reminder")
            return
        }
        #expect(calendar.component(.day, from: date) == 18)
    }

    @Test("A list offers to be kept")
    func note() {
        #expect(suggestions("""
        Vi skal bruge:
        - tortillachips
        - tomater
        - ananas
        """).contains { $0.kind == .note })

        #expect(suggestions("We need: tortilla chips, tomatoes, pineapple, seltzer").contains { $0.kind == .note })
        #expect(SuggestionScanner.isWorthKeeping("1. møde\n2. frokost\n3. hjem"))
    }

    @Test("A message can ask for both")
    func both() {
        let found = suggestions("Husk i morgen: chips, tomater, ananas, sodavand")
        #expect(found.count == 2)
        #expect(found.contains { $0.kind == .note })
        #expect(found.contains { if case .remind = $0.kind { true } else { false } })
    }

    @Test("Ordinary chat suggests nothing")
    func quiet() {
        #expect(suggestions("god morgen!").isEmpty)
        #expect(suggestions("ja, det lyder fint").isEmpty)
        #expect(suggestions("hvad synes du om den?").isEmpty)
        // One comma is a sentence, not a list.
        #expect(suggestions("jeg siger det sådan: det virker, tror jeg").isEmpty)
        #expect(suggestions("").isEmpty)
    }
}
