import Testing
@testable import TalkCore

struct AnswerCitationsTests {
    @Test func marksBecomeIdsInOrder() {
        let parsed = AnswerCitations.parse("Anna sent the invoice on Monday [#412]. Bo paid it [#420].")
        #expect(parsed.text == "Anna sent the invoice on Monday. Bo paid it.")
        #expect(parsed.messageIDs == [412, 420])
    }

    @Test func eachMessageOnceAndGroupedMarksToo() {
        let parsed = AnswerCitations.parse("Yes [#5, #7]. Again [#5][#9].")
        #expect(parsed.messageIDs == [5, 7, 9])
        #expect(parsed.text == "Yes. Again.")
    }

    @Test func otherBracketsAreLeftAlone() {
        let parsed = AnswerCitations.parse("See [the docs] and [#x] [#3]")
        #expect(parsed.text == "See [the docs] and [#x]")
        #expect(parsed.messageIDs == [3])
    }

    @Test func anUnclosedMarkIsKept() {
        #expect(AnswerCitations.parse("Half [#12").text == "Half [#12")
    }
}
