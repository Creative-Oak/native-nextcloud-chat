import Foundation
import Testing
@testable import TalkCore

/// Turning a typed question into a search the server can answer.
@Suite("Search intent")
struct SearchIntentTests {
    @Test("A question is worth rewriting; a search term is not")
    func recognisesQuestions() {
        #expect(NaturalLanguageQuery.looksConversational("hvad sagde Heine om fakturaen"))
        #expect(NaturalLanguageQuery.looksConversational("what did Heine say about the invoice"))
        // Short searches are left alone — nobody's two-word search needs help.
        #expect(!NaturalLanguageQuery.looksConversational("faktura"))
        #expect(!NaturalLanguageQuery.looksConversational("faktura 2024"))
        #expect(!NaturalLanguageQuery.looksConversational("release notes v2"))
    }

    @Test("The words nobody writes in a message come out")
    func keywords() {
        #expect(NaturalLanguageQuery.keywords(from: "hvad sagde Heine om fakturaen") == "Heine fakturaen")
        #expect(NaturalLanguageQuery.keywords(from: "what did Heine say about the invoice") == "Heine invoice")
        // Verbs of saying are noise in a substring search: nobody writes "skrev" in the
        // message you are looking for.
        #expect(NaturalLanguageQuery.keywords(from: "hvem har skrevet om mødet?") == "mødet")
    }

    @Test("Stripping never leaves nothing behind")
    func neverEmpty() {
        // Every word is a stop word: better to search what was typed than to search nothing.
        #expect(NaturalLanguageQuery.keywords(from: "hvad sagde de om det") == "hvad sagde de om det")
        #expect(NaturalLanguageQuery.keywords(from: "   ") == "")
    }

    @Test("An intent knows when it has changed the question")
    func changes() {
        let untouched = SearchIntent(terms: "faktura", author: nil, after: nil, before: nil)
        #expect(!untouched.changesAnything(from: "faktura"))
        #expect(!untouched.changesAnything(from: " Faktura "))

        let narrowed = SearchIntent(terms: "faktura", author: "Heine", after: nil, before: nil)
        #expect(narrowed.changesAnything(from: "faktura"))
        #expect(narrowed.explanation().contains("from Heine"))
    }

    @Test("Filters the server can't apply are applied to the hits")
    func admits() {
        let day = Date(timeIntervalSince1970: 1_758_000_000)
        let intent = SearchIntent(
            terms: "faktura",
            author: "Heine",
            after: day,
            before: day.addingTimeInterval(86_400)
        )

        #expect(intent.admits(title: "Heine Volder in Bogholderi", timestamp: day.addingTimeInterval(3600)))
        // Somebody else's message, inside the window.
        #expect(!intent.admits(title: "Salina Ibrahim in Bogholderi", timestamp: day.addingTimeInterval(3600)))
        // Heine, but before the window.
        #expect(!intent.admits(title: "Heine Volder in Bogholderi", timestamp: day.addingTimeInterval(-3600)))
        // Heine, but after it.
        #expect(!intent.admits(title: "Heine Volder in Bogholderi", timestamp: day.addingTimeInterval(200_000)))
    }

    @Test("An intent with no filters admits everything")
    func admitsEverything() {
        let intent = SearchIntent(terms: "faktura", author: nil, after: nil, before: nil)
        #expect(intent.admits(title: "anybody in anywhere", timestamp: .distantPast))
        #expect(intent.admits(title: "", timestamp: .distantFuture))
    }
}
