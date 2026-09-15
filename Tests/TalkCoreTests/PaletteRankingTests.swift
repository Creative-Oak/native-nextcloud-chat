import Foundation
import Testing
@testable import TalkCore

/// The command palette lists conversations, commands and people by how well they answer
/// what was typed. The grades, and the order within a grade, are the whole of what makes
/// the top row the right one.
@Suite("Palette ranking")
struct PaletteRankingTests {
    private func rank(_ names: [String], _ query: String, limit: Int = 10) -> [String] {
        PaletteRanking.rank(names, query: query, limit: limit) { [$0] }
    }

    @Test("A whole-text prefix beats a word prefix, which beats a substring")
    func grades() {
        let names = ["Wilhelmina", "Volder Heine", "Heine Volder"]
        #expect(rank(names, "he") == ["Heine Volder", "Volder Heine", "Wilhelmina"])
    }

    @Test("Ties keep the order they came in")
    func stableWithinGrade() {
        let names = ["Meeting", "Meeting (old)", "Metrics"]
        #expect(rank(names, "me") == names)
    }

    @Test("Case, diacritics and width do not matter")
    func folding() {
        #expect(rank(["Jérôme", "Ｊerome"], "jerome") == ["Jérôme", "Ｊerome"])
        #expect(PaletteRanking.grade("JEROME", against: ["jérôme"]) == .prefix)
    }

    @Test("An empty query lists everything, in order, up to the limit")
    func emptyQuery() {
        let names = ["a", "b", "c", "d"]
        #expect(rank(names, "", limit: 3) == ["a", "b", "c"])
        #expect(rank(names, "   ", limit: 10) == names)
    }

    @Test("Any of a candidate's texts can earn the grade")
    func aliases() {
        let ranked = PaletteRanking.rank(
            [("Use Compact Sidebar", ["narrow", "faces"]), ("Refresh Conversations", ["reload"])],
            query: "narrow",
            limit: 5
        ) { [$0.0] + $0.1 }
        #expect(ranked.map(\.0) == ["Use Compact Sidebar"])
    }

    @Test("Letters in order count, below any real match")
    func fuzzy() {
        let names = ["Server Monitoring", "Meeting", "Heine Volder Rødder"]
        #expect(rank(names, "srvmon") == ["Server Monitoring"])
        #expect(rank(names, "hvr") == ["Heine Volder Rødder"])
        #expect(rank(names, "h v r") == ["Heine Volder Rødder"])
        #expect(PaletteRanking.grade("srvmon", against: ["Server Monitoring"]) == .fuzzy)
        // Out of order is not a match.
        #expect(rank(names, "rvs").isEmpty)
        // A substring still beats a fuzzy hit.
        #expect(rank(["Meeting Minutes", "Metrics"], "met") == ["Metrics", "Meeting Minutes"])
    }

    @Test("What does not match is left out, and the limit holds")
    func filteringAndLimit() {
        let names = ["Server Monitoring", "Meeting", "Talk updates", "testerinos"]
        #expect(rank(names, "xyz").isEmpty)
        #expect(rank(names, "e", limit: 2).count == 2)
    }
}
