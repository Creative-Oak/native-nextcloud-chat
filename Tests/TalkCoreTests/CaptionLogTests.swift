import Foundation
import Testing
@testable import TalkCore

struct CaptionLogTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func pendingWordsAreReplacedThenSettled() {
        var log = CaptionLog()
        log.receive("Hej", isFinal: false, from: "a", named: "Anna", at: at(0))
        log.receive("Hej Magnus", isFinal: false, from: "a", named: "Anna", at: at(0.3))
        #expect(log.lines.count == 1)
        #expect(log.lines[0].pending == "Hej Magnus")
        log.receive("Hej Magnus.", isFinal: true, from: "a", named: "Anna", at: at(0.6))
        #expect(log.lines[0].settled == "Hej Magnus.")
        #expect(log.lines[0].pending.isEmpty)
        // The next bit of the same sentence goes on after it.
        log.receive("Kan du", isFinal: false, from: "a", named: "Anna", at: at(1))
        #expect(log.lines.count == 1)
        #expect(log.lines[0].text == "Hej Magnus. Kan du")
    }

    @Test func aPauseStartsANewLine() {
        var log = CaptionLog()
        log.receive("Hi there.", isFinal: true, from: "a", named: "Anna", at: at(0))
        log.receive("Anyway", isFinal: false, from: "a", named: "Anna", at: at(3))
        #expect(log.lines.map(\.text) == ["Hi there.", "Anyway"])
        #expect(log.lines[0].isClosed)
    }

    @Test func pendingWordsKeepTheirLineHoweverLongTheyTake() {
        var log = CaptionLog()
        log.receive("I was", isFinal: false, from: "a", named: "Anna", at: at(0))
        // The model can take a while to settle; its next pending result is still this line.
        log.receive("I was calling to ask", isFinal: false, from: "a", named: "Anna", at: at(4))
        #expect(log.lines.map(\.text) == ["I was calling to ask"])
    }

    @Test func peopleTalkingOverEachOtherKeepTheirOwnLines() {
        var log = CaptionLog()
        log.receive("So what I", isFinal: false, from: "a", named: "Anna", at: at(0))
        log.receive("Sorry", isFinal: false, from: "b", named: "Bo", at: at(0.2))
        log.receive("So what I meant", isFinal: false, from: "a", named: "Anna", at: at(0.4))
        #expect(log.lines.map(\.speaker) == ["Anna", "Bo"])
        #expect(log.lines[0].text == "So what I meant")
    }

    @Test func aLongLineEnds() {
        var log = CaptionLog()
        log.lineLength = 20
        log.receive("This sentence is long enough.", isFinal: true, from: "a", named: "Anna", at: at(0))
        log.receive("Next", isFinal: false, from: "a", named: "Anna", at: at(0.5))
        #expect(log.lines.count == 2)
    }

    @Test func linesLeaveTheScreenAfterAWhile() {
        var log = CaptionLog()
        log.receive("One.", isFinal: true, from: "a", named: "Anna", at: at(0))
        log.receive("Two.", isFinal: true, from: "b", named: "Bo", at: at(5))
        #expect(log.visible(at: at(6)).map(\.text) == ["One.", "Two."])
        #expect(log.visible(at: at(8)).map(\.text) == ["Two."])
        #expect(log.visible(at: at(13)).isEmpty)
    }

    @Test func onlyTheLastFewAreShown() {
        var log = CaptionLog()
        for (index, speaker) in ["a", "b", "c", "d"].enumerated() {
            log.receive("Line \(index).", isFinal: true, from: speaker, named: speaker, at: at(Double(index) * 0.1))
        }
        #expect(log.visible(at: at(1)).map(\.text) == ["Line 1.", "Line 2.", "Line 3."])
    }

    @Test func nothingToSayMakesNoLine() {
        var log = CaptionLog()
        log.receive("  ", isFinal: false, from: "a", named: "Anna", at: at(0))
        log.receive("", isFinal: true, from: "a", named: "Anna", at: at(0.1))
        #expect(log.lines.isEmpty)
    }

    @Test func closingDropsWordsNeverSettledOn() {
        var log = CaptionLog()
        log.receive("Bye.", isFinal: true, from: "a", named: "Anna", at: at(0))
        log.receive("And one more", isFinal: false, from: "a", named: "Anna", at: at(0.5))
        log.close(speakerID: "a")
        #expect(log.lines[0].text == "Bye.")
        #expect(log.lines[0].isClosed)
        log.receive("Hello", isFinal: false, from: "a", named: "Anna", at: at(1))
        #expect(log.lines.count == 2)
    }

    @Test func theTranscriptIsEverythingSaidWithWhoSaidIt() {
        var log = CaptionLog()
        log.receive("Shall we start?", isFinal: true, from: "a", named: "Anna", at: at(0))
        log.receive("Yes", isFinal: true, from: "b", named: "Bo", at: at(1))
        log.receive("I was just", isFinal: false, from: "a", named: "Anna", at: at(5))
        #expect(log.transcript == [
            SummaryInput.Line(author: "Anna", text: "Shall we start?"),
            SummaryInput.Line(author: "Bo", text: "Yes"),
            SummaryInput.Line(author: "Anna", text: "I was just")
        ])
        // A line that ended mid-word keeps only what was settled.
        log.close(speakerID: "a")
        #expect(log.transcript.count == 2)
    }
}
